//! HOST runtime (Node axis — NOT ECMA-262): a minimal but real `http` SERVER. `require('http')` /
//! `require('node:http')`. HOST-only — never on the Test262 path (a server can only be created from
//! `ljs run`, which drives the libxev loop).
//!
//! Built ABOVE the `net` module (host_net.zig): an `http.Server` owns an internal `net.Server` and is
//! driven entirely through net's JS surface (`net.createServer`, `server.listen`, and per-socket
//! `'data'`/`'end'`/`'close'` events + `socket.write`/`socket.end`). All the libxev plumbing lives in
//! `net`; this module is a pure protocol layer (HTTP/1.1 request parse + response serialize).
//!
//! Objects:
//!   • `http.Server` — an EventEmitter (proto chains into `%EventEmitter.prototype%`). The user's
//!     `requestListener` is added as a `'request'` listener. On each net connection we attach a
//!     per-socket parser and, once a full request is parsed, build `req`/`res` and emit `'request'`.
//!   • `req` (IncomingMessage) — a readable EventEmitter: `.method`/`.url`/`.httpVersion`/`.headers`/
//!     `.socket`/`.connection`; emits `'data'` (Buffer body) then `'end'` (always, even with no body).
//!   • `res` (ServerResponse) — a writable EventEmitter: `.statusCode`/`.statusMessage`/`setHeader`/
//!     `getHeader`/`hasHeader`/`removeHeader`/`writeHead`/`write`/`end`/`.headersSent`. The first
//!     write/end serializes the status line + headers (adds `Date`, `Content-Length` or
//!     `Connection: close`) then the body; `.end()` finishes + closes the socket (no keep-alive v1).
//!
//! Per-connection parser state (`*ConnState`) is kept in `interp.io_handles` keyed by a hidden
//! `"%http%"` own prop on the socket JS object (same registry pattern as host_net's `*SocketState`).
//!
//! CLIENT (added): `http.request(options|url[, options][, cb])` / `http.get(...)` → a `ClientRequest`
//! (a writable EventEmitter). On `.end()` it drives a `net.Socket` (connect, write the request, then
//! accumulate the response), parses the status line + headers + body, and emits `'response'` with a
//! readable IncomingMessage (`.statusCode`/`.statusMessage`/`.httpVersion`/`.headers`, `'data'`/`'end'`).
//! Body framing: `Content-Length`, `Transfer-Encoding: chunked` (decoded), else read-until-close.
//! Plaintext `http://` only — NO TLS (`https://` is a later slice).
//!
//! SKIPPED (noted, not bugs): server keep-alive / pipelining (every RESPONSE is `Connection: close`),
//! server chunked send (responses always emit a fixed `Content-Length`), HTTPS/TLS, `Expect:
//! 100-continue`, trailers, client redirects / connection-pooling / agents.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_require = @import("host_require.zig");
const host_buffer = @import("host_buffer.zig");
const host_process = @import("host_process.zig");
const host_net = @import("host_net.zig");

const CONN_KEY = "%http%"; // hidden own prop on a socket → its *ConnState id in io_handles
const RES_KEY = "%httpres%"; // hidden own prop on a res → its *ResState id in io_handles
const CLIENT_KEY = "%httpclient%"; // hidden own prop on a ClientRequest / its socket → its *ClientState id

// ── per-connection parser state ───────────────────────────────────────────────────

/// HTTP/1.1 request parser state for one accepted socket. Arena-allocated (stable address). Accumulates
/// raw bytes until the header block (`\r\n\r\n`) is seen, then the body per `Content-Length`.
const ConnState = struct {
    interp: *Interpreter,
    socket: *Object, // the net Socket JS object
    server: *Object, // the http.Server JS object
    buf: std.ArrayListUnmanaged(u8) = .empty,
    headers_done: bool = false,
    dispatched: bool = false, // 'request' already emitted for the CURRENT request
    content_length: usize = 0,
    have_content_length: bool = false,
    body_start: usize = 0, // index in `buf` where the body begins
    req: ?*Object = null, // the IncomingMessage once built (to stream body + 'end')
    keep_alive: bool = false, // the client wants a persistent connection (HTTP/1.1 default / explicit)
};

/// Per-response serialization state.
const ResState = struct {
    interp: *Interpreter,
    res: *Object,
    socket: *Object,
    headers_sent: bool = false,
    finished: bool = false,
    // Ordered header list (lowercased-name lookup, original-case emit). Small N → linear scan.
    names: std.ArrayListUnmanaged([]const u8) = .empty, // original case
    lower: std.ArrayListUnmanaged([]const u8) = .empty, // lowercased, parallel to names/values
    values: std.ArrayListUnmanaged([]const u8) = .empty,
    status_code: u16 = 200,
    status_message: ?[]const u8 = null,
    keep_alive: bool = false, // decided at header-serialize time (client wants it AND body framing is known)
};

/// CLIENT request/response state for one outgoing `http.request`. Arena-allocated (stable address).
/// Owns the outgoing header list (built via setHeader/options) + body buffer, and once connected the
/// incoming response parser state. Registered on the ClientRequest JS object (and its socket) via
/// `CLIENT_KEY` in `io_handles`.
const ClientState = struct {
    interp: *Interpreter,
    req: *Object, // the ClientRequest JS object (a writable EventEmitter)
    socket: ?*Object = null, // the net.Socket once connect() is called

    // Request line + outgoing headers (parallel name/lower/value lists, like ResState).
    method: []const u8 = "GET",
    path: []const u8 = "/",
    host: []const u8 = "127.0.0.1", // for the Host header (hostname[:port])
    hostname: []const u8 = "127.0.0.1", // for net.connect
    port: u16 = 80,
    names: std.ArrayListUnmanaged([]const u8) = .empty, // original case
    lower: std.ArrayListUnmanaged([]const u8) = .empty,
    values: std.ArrayListUnmanaged([]const u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,

    sent: bool = false, // request bytes written (end() called)
    aborted: bool = false,

    // ── incoming response parser ──
    in: std.ArrayListUnmanaged(u8) = .empty,
    headers_done: bool = false,
    res: ?*Object = null, // the response IncomingMessage once headers parsed
    res_emitted: bool = false,
    body_start: usize = 0,
    content_length: usize = 0,
    have_content_length: bool = false,
    chunked: bool = false,
    body_consumed: usize = 0, // bytes of the (content-length) body already emitted as 'data'
    chunk_offset: usize = 0, // parser cursor into `in` for chunked decoding
    finished: bool = false, // 'end' emitted on the response
    res_encoding: ?[]const u8 = null, // setEncoding on the response → emit strings not Buffers
};

// ── module construction ─────────────────────────────────────────────────────────

/// Build the `http` core-module exports: `{ createServer, Server, IncomingMessage, ServerResponse,
/// METHODS, STATUS_CODES }`. `Server`/`IncomingMessage`/`ServerResponse` carry prototypes whose
/// `[[Prototype]]` chains into `%EventEmitter.prototype%`.
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const ee_proto = try eventEmitterProto(self);

    const mod = try Object.create(arena, self.objectProto());

    // Server.prototype + Server constructor.
    const server_proto = try Object.create(arena, ee_proto);
    for ([_][]const u8{ "listen", "close", "address", "setTimeout" }) |m|
        try defineHttpMethod(self, server_proto, m, m); // statics-style name; dispatched on instance
    const server_ctor = try makeCtor(self, "Server");
    try server_ctor.defineData("prototype", .{ .object = server_proto }, false, false, false);
    try server_proto.defineData("constructor", .{ .object = server_ctor }, true, false, true);

    // IncomingMessage.prototype + constructor (a readable; its own methods are inherited EE ones).
    const req_proto = try Object.create(arena, ee_proto);
    for ([_][]const u8{ "setEncoding", "pause", "resume" }) |m|
        try defineHttpMethod(self, req_proto, m, m);
    const req_ctor = try makeCtor(self, "IncomingMessage");
    try req_ctor.defineData("prototype", .{ .object = req_proto }, false, false, false);
    try req_proto.defineData("constructor", .{ .object = req_ctor }, true, false, true);

    // ServerResponse.prototype + constructor.
    const res_proto = try Object.create(arena, ee_proto);
    for ([_][]const u8{
        "setHeader", "getHeader", "hasHeader", "removeHeader", "getHeaderNames",
        "writeHead", "write",     "end",       "flushHeaders",
    }) |m| try defineHttpMethod(self, res_proto, m, m);
    const res_ctor = try makeCtor(self, "ServerResponse");
    try res_ctor.defineData("prototype", .{ .object = res_proto }, false, false, false);
    try res_proto.defineData("constructor", .{ .object = res_ctor }, true, false, true);

    // ClientRequest.prototype + constructor (a writable EventEmitter — the http.request return value).
    const creq_proto = try Object.create(arena, ee_proto);
    for ([_][]const u8{
        "write",      "end",          "setHeader", "getHeader",
        "hasHeader",  "removeHeader", "abort",     "destroy",
        "setTimeout", "flushHeaders",
    }) |m| try defineHttpMethod(self, creq_proto, m, m);
    const creq_ctor = try makeCtor(self, "ClientRequest");
    try creq_ctor.defineData("prototype", .{ .object = creq_proto }, false, false, false);
    try creq_proto.defineData("constructor", .{ .object = creq_ctor }, true, false, true);

    try mod.defineData("Server", .{ .object = server_ctor }, true, false, true);
    try mod.defineData("IncomingMessage", .{ .object = req_ctor }, true, false, true);
    try mod.defineData("ServerResponse", .{ .object = res_ctor }, true, false, true);
    try mod.defineData("ClientRequest", .{ .object = creq_ctor }, true, false, true);
    try defineHttpMethod(self, mod, "createServer", "createServer");
    try defineHttpMethod(self, mod, "request", "request");
    try defineHttpMethod(self, mod, "get", "get");

    // The internal connection trampoline — a `.http_method` native bound to a server, registered as
    // net 'connection' / socket 'data'/'end' listeners. Hidden behind `native_name`.
    try defineHttpMethod(self, mod, "%onConnection%", "%onConnection%");
    try defineHttpMethod(self, mod, "%onData%", "%onData%");
    try defineHttpMethod(self, mod, "%onEnd%", "%onEnd%");
    // Client-side socket trampolines (registered as net 'connect'/'data'/'end'/'error'/'close').
    try defineHttpMethod(self, mod, "%clConnect%", "%clConnect%");
    try defineHttpMethod(self, mod, "%clData%", "%clData%");
    try defineHttpMethod(self, mod, "%clEnd%", "%clEnd%");
    try defineHttpMethod(self, mod, "%clError%", "%clError%");

    return mod;
}

/// `%EventEmitter.prototype%` from the (cached) `events` core module.
fn eventEmitterProto(self: *Interpreter) EvalError!?*Object {
    const ee = try host_require.loadCoreModulePub(self, "events");
    if (ee.normal == .object) {
        if (ee.normal.object.get("prototype")) |p| if (p == .object) return p.object;
    }
    return self.objectProto();
}

fn makeCtor(self: *Interpreter, name: []const u8) EvalError!*Object {
    const ctor = try Object.createNative(self.arena, .http_method, name);
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = name }, false, false, true);
    return ctor;
}

fn defineHttpMethod(self: *Interpreter, target: *Object, key: []const u8, native_name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .http_method, native_name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = key }, false, false, true);
    try target.defineData(key, .{ .object = fn_obj }, true, false, key[0] != '%');
}

// ── dispatch ──────────────────────────────────────────────────────────────────────

/// Dispatch a `.http_method` native by `func.native_name`.
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;

    if (eq(u8, name, "createServer")) return createServer(self, args, null);
    if (eq(u8, name, "request")) return clientRequest(self, args, false);
    if (eq(u8, name, "get")) return clientRequest(self, args, true);
    if (eq(u8, name, "Server")) return serverCtor(self, this_val, args);
    if (eq(u8, name, "IncomingMessage") or eq(u8, name, "ServerResponse") or eq(u8, name, "ClientRequest")) {
        // Direct construction is allowed but uncommon; return the receiver (state attached lazily).
        return .{ .normal = if (self.native_new_target != .undefined) this_val else .undefined };
    }

    // Internal trampolines (registered as net listeners; `this_val` is the emitter that fired).
    if (eq(u8, name, "%onConnection%")) return onConnection(self, func, args);
    if (eq(u8, name, "%onData%")) return onData(self, this_val, args);
    if (eq(u8, name, "%onEnd%")) return onEnd(self, this_val);
    if (eq(u8, name, "%relay%")) return relayFire(self, func, args);
    if (eq(u8, name, "%clConnect%")) return clOnConnect(self, func);
    if (eq(u8, name, "%clData%")) return clOnData(self, func, args);
    if (eq(u8, name, "%clEnd%")) return clOnEnd(self, func);
    if (eq(u8, name, "%clError%")) return clOnError(self, func, args);

    // Instance methods — receiver must be an object.
    if (this_val != .object) return self.throwError("TypeError", "http method called on non-object");
    const js = this_val.object;

    // ClientRequest methods (dispatched FIRST when the receiver carries a ClientState, since several
    // method NAMES — write/end/setHeader/... — collide with ServerResponse's).
    if (clientStateOf(self, js)) |cl| {
        if (eq(u8, name, "write")) return clientWrite(self, cl, this_val, args);
        if (eq(u8, name, "end")) return clientEnd(self, cl, this_val, args);
        if (eq(u8, name, "setHeader")) return clientSetHeader(self, cl, this_val, args);
        if (eq(u8, name, "getHeader")) return clientGetHeader(self, cl, args);
        if (eq(u8, name, "hasHeader")) return .{ .normal = .{ .boolean = clientHeaderIndex(cl, try lowerDup(self, headerArgName(args))) != null } };
        if (eq(u8, name, "removeHeader")) return clientRemoveHeader(self, cl, this_val, args);
        if (eq(u8, name, "abort") or eq(u8, name, "destroy")) {
            cl.aborted = true;
            if (cl.socket) |s| try socketEnd(self, s);
            return .{ .normal = this_val };
        }
        if (eq(u8, name, "setTimeout")) {
            if (args.len > 1 and args[1] == .object and args[1].object.kind == .function)
                try jsAddListener(self, js, "timeout", args[1], true);
            return .{ .normal = this_val };
        }
        if (eq(u8, name, "flushHeaders")) return .{ .normal = this_val };
        if (eq(u8, name, "setEncoding")) {
            // A client-side RESPONSE IncomingMessage also carries CLIENT_KEY.
            cl.res_encoding = if (args.len > 0 and args[0] == .string) self.arena.dupe(u8, args[0].string) catch null else null;
            return .{ .normal = this_val };
        }
    }

    // Server methods.
    if (eq(u8, name, "listen")) return serverListen(self, js, this_val, args);
    if (eq(u8, name, "close")) return serverCloseMethod(self, js, this_val, args);
    if (eq(u8, name, "address")) return serverAddress(self, js);
    if (eq(u8, name, "setTimeout")) return .{ .normal = this_val };

    // ServerResponse methods.
    if (eq(u8, name, "setHeader")) return resSetHeader(self, js, this_val, args);
    if (eq(u8, name, "getHeader")) return resGetHeader(self, js, args);
    if (eq(u8, name, "hasHeader")) return resHasHeader(self, js, args);
    if (eq(u8, name, "removeHeader")) return resRemoveHeader(self, js, this_val, args);
    if (eq(u8, name, "getHeaderNames")) return resGetHeaderNames(self, js);
    if (eq(u8, name, "writeHead")) return resWriteHead(self, js, this_val, args);
    if (eq(u8, name, "write")) return resWrite(self, js, args);
    if (eq(u8, name, "end")) return resEnd(self, js, this_val, args);
    if (eq(u8, name, "flushHeaders")) {
        const st = resStateOf(self, js) orelse return .{ .normal = this_val };
        try ensureHeadersSent(self, st);
        return .{ .normal = this_val };
    }

    // IncomingMessage methods — setEncoding/pause/resume are forwarded to the underlying socket.
    if (eq(u8, name, "setEncoding") or eq(u8, name, "pause") or eq(u8, name, "resume")) {
        if (js.get("socket")) |sv| if (sv == .object) {
            if (sv.object.get(name)) |m| if (m == .object and m.object.kind == .function) {
                _ = try self.callFunction(m.object, args, sv);
            };
        };
        return .{ .normal = this_val };
    }

    return .{ .normal = .undefined };
}

// ── handle registry (per-connection / per-response native state) ───────────────────

fn registerHandle(self: *Interpreter, js: *Object, key: []const u8, ptr: *anyopaque) EvalError!void {
    const id = self.next_io_id;
    self.next_io_id += 1;
    self.io_handles.put(self.arena, id, ptr) catch return error.OutOfMemory;
    try js.defineData(key, .{ .number = @floatFromInt(id) }, false, false, false);
}

fn handlePtr(self: *Interpreter, js: *Object, key: []const u8) ?*anyopaque {
    const v = js.get(key) orelse return null;
    if (v != .number) return null;
    const id: u64 = @intFromFloat(v.number);
    return self.io_handles.get(id);
}

fn connStateOf(self: *Interpreter, js: *Object) ?*ConnState {
    const p = handlePtr(self, js, CONN_KEY) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn resStateOf(self: *Interpreter, js: *Object) ?*ResState {
    const p = handlePtr(self, js, RES_KEY) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn clientStateOf(self: *Interpreter, js: *Object) ?*ClientState {
    const p = handlePtr(self, js, CLIENT_KEY) orelse return null;
    return @ptrCast(@alignCast(p));
}

// ── http.Server ────────────────────────────────────────────────────────────────────

fn serverCtor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target != .undefined and this_val == .object) {
        try initServer(self, this_val.object, args);
        return .{ .normal = this_val };
    }
    return createServer(self, args, null);
}

/// `http.createServer([options,] [requestListener])`. Builds an http.Server whose `[[Prototype]]` is
/// `http.Server.prototype`; the requestListener (last function arg) is added as a `'request'` listener.
fn createServer(self: *Interpreter, args: []const Value, into: ?*Object) EvalError!Completion {
    const js = if (into) |o| o else blk: {
        const proto = try ctorProto(self, "Server");
        break :blk try Object.create(self.arena, proto);
    };
    try initServer(self, js, args);
    return .{ .normal = .{ .object = js } };
}

fn initServer(self: *Interpreter, js: *Object, args: []const Value) EvalError!void {
    // Initialize the EventEmitter store on the server (calling its inherited EE state init lazily is
    // fine, but adding a listener below will create it). Add the requestListener as 'request'.
    for (args) |a| if (a == .object and a.object.kind == .function) {
        try jsAddListener(self, js, "request", a, false);
    };
}

/// The `prototype` object of `http.<name>` (Server/IncomingMessage/ServerResponse).
fn ctorProto(self: *Interpreter, name: []const u8) EvalError!?*Object {
    const http_mod = (try host_require.loadCoreModulePub(self, "http")).normal.object;
    if (http_mod.get(name)) |c| if (c == .object)
        if (c.object.get("prototype")) |p| if (p == .object) return p.object;
    return self.objectProto();
}

/// `server.listen(port[, host][, callback])`. Creates+listens an internal `net.Server`, wiring its
/// 'connection' event to our trampoline. The callback / 'listening' fires when bound.
fn serverListen(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    // Build a net.Server with our connection trampoline (a `.http_method` native bound to `js`).
    const net_mod = (try host_require.loadCoreModulePub(self, "net")).normal.object;
    const create_v = net_mod.get("createServer") orelse return self.throwError("Error", "net.createServer unavailable");
    if (create_v != .object) return self.throwError("Error", "net.createServer unavailable");

    const on_conn = try boundTrampoline(self, "%onConnection%", js);
    const net_server_c = try self.callFunction(create_v.object, &.{.{ .object = on_conn }}, .{ .object = net_mod });
    if (net_server_c.isAbrupt()) return net_server_c;
    if (net_server_c.normal != .object) return self.throwError("Error", "net.createServer did not return a server");
    const net_server = net_server_c.normal.object;
    try js.defineData("%netserver%", .{ .object = net_server }, false, false, false);

    // A 'listening' callback (the last function arg) fires once bound — forward to net's listen cb.
    // Also relay net's 'listening' → our server's 'listening'.
    var listen_cb: Value = .undefined;
    for (args) |a| if (a == .object and a.object.kind == .function) {
        listen_cb = a;
    };
    if (listen_cb != .undefined) try jsAddListener(self, js, "listening", listen_cb, true);
    try relayEvent(self, net_server, js, "listening");
    try relayEvent(self, net_server, js, "error");
    try relayEvent(self, net_server, js, "close");

    // Forward port/host (drop any callback — we already captured it) to net.Server.listen.
    const listen_v = net_server.get("listen") orelse return self.throwError("Error", "net listen unavailable");
    if (listen_v != .object) return self.throwError("Error", "net listen unavailable");
    var fwd = std.ArrayListUnmanaged(Value).empty;
    for (args) |a| if (!(a == .object and a.object.kind == .function)) {
        fwd.append(self.arena, a) catch return error.OutOfMemory;
    };
    const lc = try self.callFunction(listen_v.object, fwd.items, .{ .object = net_server });
    if (lc.isAbrupt()) return lc;
    return .{ .normal = this_val };
}

fn serverCloseMethod(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    if (args.len > 0 and args[0] == .object and args[0].object.kind == .function)
        try jsAddListener(self, js, "close", args[0], true);
    if (js.get("%netserver%")) |nv| if (nv == .object) {
        if (nv.object.get("close")) |cv| if (cv == .object and cv.object.kind == .function) {
            _ = try self.callFunction(cv.object, &.{}, nv);
        };
    };
    return .{ .normal = this_val };
}

fn serverAddress(self: *Interpreter, js: *Object) EvalError!Completion {
    if (js.get("%netserver%")) |nv| if (nv == .object) {
        if (nv.object.get("address")) |av| if (av == .object and av.object.kind == .function)
            return self.callFunction(av.object, &.{}, nv);
    };
    return .{ .normal = .null };
}

/// Make a `.http_method` trampoline native bound to `server` (via a hidden `"%server%"` own prop) so
/// the connection/data/end callbacks can find their http.Server.
fn boundTrampoline(self: *Interpreter, native_name: []const u8, server: *Object) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .http_method, native_name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%server%", .{ .object = server }, false, false, false);
    return fn_obj;
}

/// Relay `event` from `src` emitter to `dst` emitter (forwarding the same args).
fn relayEvent(self: *Interpreter, src: *Object, dst: *Object, event: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .http_method, "%relay%");
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%dst%", .{ .object = dst }, false, false, false);
    try fn_obj.defineData("%event%", .{ .string = event }, false, false, false);
    try jsAddListener(self, src, event, .{ .object = fn_obj }, false);
}

// ── connection trampoline (net 'connection' → per-socket parser) ─────────────────────

fn onConnection(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const server = (func.get("%server%") orelse return .{ .normal = .undefined });
    if (server != .object) return .{ .normal = .undefined };
    const socket_v: Value = if (args.len > 0) args[0] else .undefined;
    if (socket_v != .object) return .{ .normal = .undefined };
    const socket = socket_v.object;

    // Attach a parser ConnState to this socket.
    const st = self.arena.create(ConnState) catch return error.OutOfMemory;
    st.* = .{ .interp = self, .socket = socket, .server = server.object };
    try registerHandle(self, socket, CONN_KEY, st);

    // Register data/end listeners (bound to the socket via its own %http% handle; we look ConnState up
    // off the socket receiver, so a plain bound trampoline suffices).
    const on_data = try Object.createNative(self.arena, .http_method, "%onData%");
    on_data.prototype = self.functionProto();
    _ = on_data.properties.orderedRemove("prototype");
    const on_end = try Object.createNative(self.arena, .http_method, "%onEnd%");
    on_end.prototype = self.functionProto();
    _ = on_end.properties.orderedRemove("prototype");
    try jsAddListener(self, socket, "data", .{ .object = on_data }, false);
    try jsAddListener(self, socket, "end", .{ .object = on_end }, false);
    return .{ .normal = .undefined };
}

/// A socket 'data' chunk: append to the parser buffer and try to advance parsing. `this_socket` is the
/// net Socket the listener fired on.
fn onData(self: *Interpreter, this_socket: Value, args: []const Value) EvalError!Completion {
    if (this_socket != .object) return .{ .normal = .undefined };
    const st = connStateOf(self, this_socket.object) orelse return .{ .normal = .undefined };
    const chunk = try valueToBytes(self, if (args.len > 0) args[0] else .undefined);
    st.buf.appendSlice(self.arena, chunk) catch return error.OutOfMemory;
    try advance(self, st);
    return .{ .normal = .undefined };
}

/// The socket ended (peer FIN): if a request is in flight but its body wasn't fully received, finish it.
fn onEnd(self: *Interpreter, this_socket: Value) EvalError!Completion {
    if (this_socket != .object) return .{ .normal = .undefined };
    const st = connStateOf(self, this_socket.object) orelse return .{ .normal = .undefined };
    if (st.dispatched and st.req != null) {
        // Flush whatever body we have and emit 'end' (handles a body shorter than Content-Length / a
        // connection-close-delimited body).
        try finishRequest(self, st);
    }
    return .{ .normal = .undefined };
}

/// A `%relay%` trampoline: re-emit its `%event%` on `%dst%` with the forwarded args.
fn relayFire(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const dst = func.get("%dst%") orelse return .{ .normal = .undefined };
    const ev = func.get("%event%") orelse return .{ .normal = .undefined };
    if (dst != .object or ev != .string) return .{ .normal = .undefined };
    emitSafe(self, dst.object, ev.string, args);
    return .{ .normal = .undefined };
}

// ── request parse ───────────────────────────────────────────────────────────────────

/// Advance the parser with whatever is currently buffered. Parses the header block once, then waits for
/// `Content-Length` bytes (or dispatches immediately if no body is expected).
fn advance(self: *Interpreter, st: *ConnState) EvalError!void {
    if (st.dispatched) return; // one request per connection (no keep-alive)
    if (!st.headers_done) {
        const sep = std.mem.indexOf(u8, st.buf.items, "\r\n\r\n") orelse return; // need full header block
        st.headers_done = true;
        st.body_start = sep + 4;
        try buildAndDispatch(self, st, st.buf.items[0..sep]);
    }
    if (st.dispatched and st.req != null) {
        // Stream the body once Content-Length is satisfied (or there is no body).
        const available = st.buf.items.len - st.body_start;
        if (!st.have_content_length or st.content_length == 0) {
            try finishRequest(self, st);
        } else if (available >= st.content_length) {
            try finishRequest(self, st);
        }
    }
}

/// Parse the request-line + header block, build `req`/`res`, and emit `'request'` on the server.
fn buildAndDispatch(self: *Interpreter, st: *ConnState, header_block: []const u8) EvalError!void {
    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    const request_line = lines.next() orelse return badRequest(self, st);

    // METHOD SP url SP HTTP/x.y
    var rl = std.mem.splitScalar(u8, request_line, ' ');
    const method_s = rl.next() orelse return badRequest(self, st);
    const url_s = rl.next() orelse return badRequest(self, st);
    const version_tok = rl.next() orelse "HTTP/1.1";
    const http_version = if (std.mem.startsWith(u8, version_tok, "HTTP/")) version_tok["HTTP/".len..] else "1.1";

    // Build req (IncomingMessage).
    const req_proto = try ctorProto(self, "IncomingMessage");
    const req = try Object.create(self.arena, req_proto.?);
    const headers_obj = try Object.create(self.arena, self.objectProto());

    var conn_hdr: []const u8 = "";
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue; // malformed header line → ignore
        const raw_name = std.mem.trim(u8, line[0..colon], " \t");
        const raw_val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (raw_name.len == 0) continue;
        const lname = try lowerDup(self, raw_name);
        const val = self.arena.dupe(u8, raw_val) catch return error.OutOfMemory;
        // Last value wins for a duplicate simple header (sufficient for the common path; Node joins
        // some with ", " — out of scope here).
        try headers_obj.defineData(lname, .{ .string = val }, true, true, true);
        if (std.ascii.eqlIgnoreCase(lname, "content-length")) {
            st.content_length = std.fmt.parseInt(usize, raw_val, 10) catch 0;
            st.have_content_length = true;
        }
        if (std.ascii.eqlIgnoreCase(lname, "connection")) conn_hdr = raw_val;
    }
    // Persistent-connection decision: HTTP/1.1 defaults to keep-alive unless `Connection: close`;
    // HTTP/1.0 defaults to close unless `Connection: keep-alive`.
    const is_11 = std.mem.startsWith(u8, http_version, "1.1");
    st.keep_alive = if (is_11)
        !std.ascii.eqlIgnoreCase(conn_hdr, "close")
    else
        std.ascii.eqlIgnoreCase(conn_hdr, "keep-alive");

    try req.defineData("method", .{ .string = try self.arena.dupe(u8, method_s) }, true, true, true);
    try req.defineData("url", .{ .string = try self.arena.dupe(u8, url_s) }, true, true, true);
    try req.defineData("httpVersion", .{ .string = try self.arena.dupe(u8, http_version) }, true, true, true);
    try req.defineData("headers", .{ .object = headers_obj }, true, true, true);
    try req.defineData("socket", .{ .object = st.socket }, true, true, true);
    try req.defineData("connection", .{ .object = st.socket }, true, true, true);
    try req.defineData("complete", .{ .boolean = false }, true, true, true);
    // The EE store is created lazily by `.on`; nothing more needed here.
    st.req = req;

    // Build res (ServerResponse) bound to the same socket.
    const res = try buildResponse(self, st.socket);

    st.dispatched = true;
    // Emit 'request' on the server (this invokes the user's requestListener via the EE store).
    emitSafe(self, st.server, "request", &.{ .{ .object = req }, .{ .object = res } });
}

/// Emit body 'data' (if any) then 'end' on `st.req`, exactly once.
fn finishRequest(self: *Interpreter, st: *ConnState) EvalError!void {
    const req = st.req orelse return;
    st.req = null; // guard: emit end only once
    const body = st.buf.items[@min(st.body_start, st.buf.items.len)..];
    const n = if (st.have_content_length) @min(body.len, st.content_length) else body.len;
    if (n > 0) {
        const buf = try host_buffer.makeBufferFromBytes(self, body[0..n]);
        emitSafe(self, req, "data", &.{.{ .object = buf }});
    }
    try req.defineData("complete", .{ .boolean = true }, true, true, true);
    emitSafe(self, req, "end", &.{});
}

/// Keep-alive: after a response, drop the consumed request bytes (header block + body) from the buffer,
/// reset the parser, and re-drive it so an already-pipelined next request dispatches immediately. The
/// socket stays open; subsequent requests arrive via `onData`.
fn resetForNext(self: *Interpreter, conn: *ConnState) EvalError!void {
    const consumed = @min(conn.body_start + conn.content_length, conn.buf.items.len);
    const tail_len = conn.buf.items.len - consumed;
    if (consumed > 0 and tail_len > 0) std.mem.copyForwards(u8, conn.buf.items[0..tail_len], conn.buf.items[consumed..]);
    conn.buf.shrinkRetainingCapacity(tail_len);
    conn.headers_done = false;
    conn.dispatched = false;
    conn.content_length = 0;
    conn.have_content_length = false;
    conn.body_start = 0;
    conn.req = null;
    conn.keep_alive = false;
    try advance(self, conn);
}

/// 400 Bad Request on a malformed request line — write a minimal response and close.
fn badRequest(self: *Interpreter, st: *ConnState) EvalError!void {
    st.dispatched = true;
    const payload = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    try socketWrite(self, st.socket, payload);
    try socketEnd(self, st.socket);
}

// ── ServerResponse ───────────────────────────────────────────────────────────────────

fn buildResponse(self: *Interpreter, socket: *Object) EvalError!*Object {
    const res_proto = try ctorProto(self, "ServerResponse");
    const res = try Object.create(self.arena, res_proto.?);
    const st = self.arena.create(ResState) catch return error.OutOfMemory;
    st.* = .{ .interp = self, .res = res, .socket = socket };
    try registerHandle(self, res, RES_KEY, st);
    // Public, writable data props mirroring Node (statusCode read by ensureHeadersSent off the object so
    // user assignments `res.statusCode = 201` are honored).
    try res.defineData("statusCode", .{ .number = 200 }, true, true, true);
    try res.defineData("statusMessage", .undefined, true, true, true);
    try res.defineData("headersSent", .{ .boolean = false }, true, false, true);
    try res.defineData("finished", .{ .boolean = false }, true, true, true);
    try res.defineData("writableEnded", .{ .boolean = false }, true, true, true);
    try res.defineData("socket", .{ .object = socket }, true, true, true);
    try res.defineData("connection", .{ .object = socket }, true, true, true);
    return res;
}

fn headerIndex(st: *ResState, lname: []const u8) ?usize {
    for (st.lower.items, 0..) |l, i| if (std.ascii.eqlIgnoreCase(l, lname)) return i;
    return null;
}

fn resSetHeader(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = this_val };
    if (st.headers_sent) return self.throwError("Error", "Cannot set headers after they are sent to the client");
    if (args.len < 1 or args[0] != .string) return .{ .normal = this_val };
    const name = args[0].string;
    const val = try headerValueToString(self, if (args.len > 1) args[1] else .undefined);
    const lname = try lowerDup(self, name);
    if (headerIndex(st, lname)) |i| {
        st.values.items[i] = val;
        st.names.items[i] = self.arena.dupe(u8, name) catch return error.OutOfMemory;
    } else {
        st.names.append(self.arena, self.arena.dupe(u8, name) catch return error.OutOfMemory) catch return error.OutOfMemory;
        st.lower.append(self.arena, lname) catch return error.OutOfMemory;
        st.values.append(self.arena, val) catch return error.OutOfMemory;
    }
    return .{ .normal = this_val };
}

fn resGetHeader(self: *Interpreter, js: *Object, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = .undefined };
    if (args.len < 1 or args[0] != .string) return .{ .normal = .undefined };
    const lname = try lowerDup(self, args[0].string);
    if (headerIndex(st, lname)) |i| return .{ .normal = .{ .string = st.values.items[i] } };
    return .{ .normal = .undefined };
}

fn resHasHeader(self: *Interpreter, js: *Object, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = .{ .boolean = false } };
    if (args.len < 1 or args[0] != .string) return .{ .normal = .{ .boolean = false } };
    const lname = try lowerDup(self, args[0].string);
    return .{ .normal = .{ .boolean = headerIndex(st, lname) != null } };
}

fn resRemoveHeader(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = this_val };
    if (args.len < 1 or args[0] != .string) return .{ .normal = this_val };
    const lname = try lowerDup(self, args[0].string);
    if (headerIndex(st, lname)) |i| {
        _ = st.names.orderedRemove(i);
        _ = st.lower.orderedRemove(i);
        _ = st.values.orderedRemove(i);
    }
    return .{ .normal = this_val };
}

fn resGetHeaderNames(self: *Interpreter, js: *Object) EvalError!Completion {
    const out = try Object.createArray(self.arena, self.arrayProto());
    const st = resStateOf(self, js) orelse return .{ .normal = .{ .object = out } };
    for (st.lower.items, 0..) |l, i| try out.arraySet(self.arena, i, .{ .string = l });
    return .{ .normal = .{ .object = out } };
}

/// `res.writeHead(statusCode[, statusMessage][, headers])`.
fn resWriteHead(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = this_val };
    if (st.headers_sent) return self.throwError("Error", "Cannot render headers after they are sent to the client");
    if (args.len > 0) {
        const nc = try self.toNumberV(args[0]);
        if (!nc.isAbrupt()) {
            const code: u16 = @intFromFloat(@max(0, @min(599, nc.normal.number)));
            st.status_code = code;
            try js.set("statusCode", .{ .number = @floatFromInt(code) });
        }
    }
    // Optional statusMessage (a string) and a headers object, in either of the two arg shapes.
    var hdr_arg: Value = .undefined;
    if (args.len > 1) {
        if (args[1] == .string) {
            st.status_message = self.arena.dupe(u8, args[1].string) catch null;
            try js.set("statusMessage", .{ .string = st.status_message.? });
            if (args.len > 2) hdr_arg = args[2];
        } else {
            hdr_arg = args[1];
        }
    }
    if (hdr_arg == .object) {
        // Merge the headers object (own enumerable string props) into our header list.
        var it = hdr_arg.object.properties.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.payload != .data) continue;
            const k = e.key_ptr.*;
            _ = try resSetHeader(self, js, this_val, &.{ .{ .string = k }, e.value_ptr.payload.data });
        }
    }
    return .{ .normal = this_val };
}

/// `res.write(chunk)` — flush headers if needed, then write the chunk to the socket.
fn resWrite(self: *Interpreter, js: *Object, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = .{ .boolean = false } };
    if (st.finished) return .{ .normal = .{ .boolean = false } };
    try ensureHeadersSent(self, st);
    const chunk = try valueToBytes(self, if (args.len > 0) args[0] else .undefined);
    if (chunk.len > 0) try socketWrite(self, st.socket, chunk);
    // A write callback (last function arg) fires best-effort after the (synchronous) queue.
    for (args[@min(1, args.len)..]) |a| if (a == .object and a.object.kind == .function) {
        _ = try self.callFunction(a.object, &.{}, .undefined);
    };
    return .{ .normal = .{ .boolean = true } };
}

/// `res.end([chunk])` — flush headers (computing Content-Length when the whole body is in this call),
/// write the final chunk, close the socket, mark finished, and emit 'finish'.
fn resEnd(self: *Interpreter, js: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const st = resStateOf(self, js) orelse return .{ .normal = this_val };
    if (st.finished) return .{ .normal = this_val };

    const chunk_v: Value = if (args.len > 0 and !(args[0] == .object and args[0].object.kind == .function)) args[0] else .undefined;
    const chunk = try valueToBytes(self, chunk_v);

    if (!st.headers_sent) {
        // We have the full body now → set Content-Length if absent (and not already chunked).
        if (headerIndex(st, "content-length") == null and headerIndex(st, "transfer-encoding") == null) {
            const cl = std.fmt.allocPrint(self.arena, "{d}", .{chunk.len}) catch return error.OutOfMemory;
            _ = try resSetHeader(self, js, this_val, &.{ .{ .string = "Content-Length" }, .{ .string = cl } });
        }
        // Coalesce the header block + body into ONE socket write (one libxev write / syscall per
        // response instead of two) — this is the common `res.end(body)` fast path.
        var out = std.ArrayListUnmanaged(u8).empty;
        try appendResponseHead(self, st, &out);
        if (chunk.len > 0) out.appendSlice(self.arena, chunk) catch return error.OutOfMemory;
        try socketWrite(self, st.socket, out.items);
    } else if (chunk.len > 0) {
        try socketWrite(self, st.socket, chunk);
    }

    st.finished = true;
    try js.set("finished", .{ .boolean = true });
    try js.set("writableEnded", .{ .boolean = true });
    // Keep-alive: reset the connection parser for the next request on the SAME socket instead of
    // closing it (then drive any already-buffered pipelined request). Else close.
    if (st.keep_alive) {
        if (connStateOf(self, st.socket)) |conn| try resetForNext(self, conn);
    } else {
        try socketEnd(self, st.socket);
    }
    emitSafe(self, js, "finish", &.{});

    // A trailing end() callback fires after finish.
    for (args[@min(1, args.len)..]) |a| if (a == .object and a.object.kind == .function) {
        _ = try self.callFunction(a.object, &.{}, .undefined);
    };
    return .{ .normal = this_val };
}

/// Serialize the status line + headers to the socket exactly once. Adds `Date` and, if neither a
/// `Content-Length` nor a `Transfer-Encoding` is set, a `Connection: close` so the peer knows the body
/// ends at EOF.
fn ensureHeadersSent(self: *Interpreter, st: *ResState) EvalError!void {
    if (st.headers_sent) return;
    var out = std.ArrayListUnmanaged(u8).empty;
    try appendResponseHead(self, st, &out);
    try socketWrite(self, st.socket, out.items);
}

/// Serialize the status line + header block into `out` (NOT written — the caller writes, so `res.end`
/// can coalesce head + body into a single socket write). Marks `headers_sent` + decides keep-alive.
fn appendResponseHead(self: *Interpreter, st: *ResState, out: *std.ArrayListUnmanaged(u8)) EvalError!void {
    st.headers_sent = true;
    try st.res.set("headersSent", .{ .boolean = true });

    // Read the (possibly user-mutated) statusCode / statusMessage off the JS object.
    var code: u16 = 200;
    if (st.res.get("statusCode")) |sv| if (sv == .number) {
        code = @intFromFloat(@max(0, @min(599, sv.number)));
    };
    var msg: []const u8 = statusText(code);
    if (st.res.get("statusMessage")) |mv| if (mv == .string and mv.string.len > 0) {
        msg = mv.string;
    };

    const status_line = std.fmt.allocPrint(self.arena, "HTTP/1.1 {d} {s}\r\n", .{ code, msg }) catch return error.OutOfMemory;
    out.appendSlice(self.arena, status_line) catch return error.OutOfMemory;

    var have_date = false;
    var have_cl = false;
    var have_conn = false;
    var have_te = false;
    for (st.names.items, 0..) |name, i| {
        out.appendSlice(self.arena, name) catch return error.OutOfMemory;
        out.appendSlice(self.arena, ": ") catch return error.OutOfMemory;
        out.appendSlice(self.arena, st.values.items[i]) catch return error.OutOfMemory;
        out.appendSlice(self.arena, "\r\n") catch return error.OutOfMemory;
        const l = st.lower.items[i];
        if (std.ascii.eqlIgnoreCase(l, "date")) have_date = true;
        if (std.ascii.eqlIgnoreCase(l, "content-length")) have_cl = true;
        if (std.ascii.eqlIgnoreCase(l, "connection")) have_conn = true;
        if (std.ascii.eqlIgnoreCase(l, "transfer-encoding")) have_te = true;
    }
    if (!have_date) {
        out.appendSlice(self.arena, "Date: ") catch return error.OutOfMemory;
        out.appendSlice(self.arena, httpDate(self)) catch return error.OutOfMemory;
        out.appendSlice(self.arena, "\r\n") catch return error.OutOfMemory;
    }
    // Keep-alive only when the client asked AND the body is self-framing (Content-Length or chunked);
    // otherwise the body is delimited by EOF and we must close. Record the decision for `resEnd`.
    const want_ka = if (connStateOf(self, st.socket)) |c| c.keep_alive else false;
    st.keep_alive = want_ka and (have_cl or have_te);
    if (!have_conn) {
        out.appendSlice(self.arena, if (st.keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n") catch return error.OutOfMemory;
    }
    out.appendSlice(self.arena, "\r\n") catch return error.OutOfMemory;
}

// ── http CLIENT (http.request / http.get) ───────────────────────────────────────────

/// The `prototype` of `http.ClientRequest`.
fn clientReqProto(self: *Interpreter) EvalError!?*Object {
    const http_mod = (try host_require.loadCoreModulePub(self, "http")).normal.object;
    if (http_mod.get("ClientRequest")) |c| if (c == .object)
        if (c.object.get("prototype")) |p| if (p == .object) return p.object;
    return self.objectProto();
}

/// First arg of a header method, as a string (`""` if absent / not a string).
fn headerArgName(args: []const Value) []const u8 {
    if (args.len > 0 and args[0] == .string) return args[0].string;
    return "";
}

/// `http.request(url | options [, options][, callback])` (and `http.get` = request then `.end()`).
/// Builds a ClientRequest, parses the target into method/host/port/path + headers, and adds the
/// trailing callback (if any) as a `'response'` listener. `auto_end` runs `.end()` before returning.
fn clientRequest(self: *Interpreter, args: []const Value, auto_end: bool) EvalError!Completion {
    const proto = try clientReqProto(self);
    const js = try Object.create(self.arena, proto.?);
    const cl = self.arena.create(ClientState) catch return error.OutOfMemory;
    cl.* = .{ .interp = self, .req = js };
    try registerHandle(self, js, CLIENT_KEY, cl);

    // Walk args: a leading string is a URL; an object is options; a function is the 'response' cb.
    var cb: Value = .undefined;
    var opts: ?*Object = null;
    for (args, 0..) |a, i| {
        if (i == 0 and a == .string) {
            try applyUrl(self, cl, a.string);
        } else if (a == .object and a.object.kind == .function) {
            cb = a;
        } else if (a == .object) {
            opts = a.object;
        }
    }
    if (opts) |o| try applyOptions(self, cl, o);

    // Default + public props mirroring Node.
    try js.defineData("method", .{ .string = try self.arena.dupe(u8, cl.method) }, true, false, true);
    try js.defineData("path", .{ .string = try self.arena.dupe(u8, cl.path) }, true, false, true);
    try js.defineData("host", .{ .string = try self.arena.dupe(u8, cl.host) }, true, false, true);
    try js.defineData("finished", .{ .boolean = false }, true, true, true);
    try js.defineData("aborted", .{ .boolean = false }, true, true, true);

    if (cb != .undefined) try jsAddListener(self, js, "response", cb, false);
    if (auto_end) _ = try clientEnd(self, cl, .{ .object = js }, &.{});
    return .{ .normal = .{ .object = js } };
}

/// Parse a `http://host[:port]/path?query` URL into the ClientState. Plaintext http only.
fn applyUrl(self: *Interpreter, cl: *ClientState, url: []const u8) EvalError!void {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        // No TLS this slice: still parse the authority/path so the request is well-formed; the connect
        // will target the given port (default 443 won't speak plaintext, but we don't reject here).
        rest = rest["https://".len..];
        cl.port = 443;
    }
    // authority = up to the first '/', '?' or '#'.
    var auth_end: usize = rest.len;
    for (rest, 0..) |c, i| if (c == '/' or c == '?' or c == '#') {
        auth_end = i;
        break;
    };
    const authority = rest[0..auth_end];
    const path_part = rest[auth_end..];
    // Strip any userinfo@.
    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| hostport = authority[at + 1 ..];
    // host[:port] (IPv6 in [..] not handled — out of scope for the plaintext client).
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        cl.hostname = try self.arena.dupe(u8, hostport[0..colon]);
        cl.port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch cl.port;
    } else {
        cl.hostname = try self.arena.dupe(u8, hostport);
        if (cl.port == 0) cl.port = 80;
    }
    cl.host = try self.arena.dupe(u8, hostport); // Host header value (host[:port] as given)
    cl.path = if (path_part.len == 0) "/" else try self.arena.dupe(u8, path_part);
}

/// Apply an options object `{ host/hostname, port, path, method, headers }` over the ClientState.
fn applyOptions(self: *Interpreter, cl: *ClientState, o: *Object) EvalError!void {
    if (o.get("hostname")) |v| if (v == .string) {
        cl.hostname = try self.arena.dupe(u8, v.string);
        cl.host = cl.hostname;
    };
    if (cl.hostname.len == 0 or std.mem.eql(u8, cl.hostname, "127.0.0.1")) {
        if (o.get("host")) |v| if (v == .string) {
            cl.hostname = try self.arena.dupe(u8, v.string);
            cl.host = cl.hostname;
        };
    }
    if (o.get("port")) |v| {
        const n = try self.toNumberV(v);
        if (!n.isAbrupt()) {
            const p = n.normal.number;
            if (!std.math.isNan(p) and p >= 0 and p <= 65535) cl.port = @intFromFloat(p);
        }
    }
    if (o.get("path")) |v| if (v == .string) {
        cl.path = try self.arena.dupe(u8, v.string);
    };
    if (o.get("method")) |v| if (v == .string) {
        cl.method = try upperDup(self, v.string);
    };
    // If both host[:port] are present and the Host header wasn't set from a URL, compose host:port for
    // the header when a non-default port is used.
    if (cl.port != 80 and cl.port != 0 and std.mem.indexOfScalar(u8, cl.host, ':') == null) {
        cl.host = std.fmt.allocPrint(self.arena, "{s}:{d}", .{ cl.hostname, cl.port }) catch cl.host;
    }
    if (o.get("headers")) |hv| if (hv == .object) {
        var it = hv.object.properties.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.payload != .data) continue;
            const k = e.key_ptr.*;
            try clientSetHeaderRaw(self, cl, k, e.value_ptr.payload.data);
        }
    };
}

fn clientHeaderIndex(cl: *ClientState, lname: []const u8) ?usize {
    for (cl.lower.items, 0..) |l, i| if (std.ascii.eqlIgnoreCase(l, lname)) return i;
    return null;
}

fn clientSetHeaderRaw(self: *Interpreter, cl: *ClientState, name: []const u8, val_v: Value) EvalError!void {
    const val = try headerValueToString(self, val_v);
    const lname = try lowerDup(self, name);
    if (clientHeaderIndex(cl, lname)) |i| {
        cl.values.items[i] = val;
        cl.names.items[i] = self.arena.dupe(u8, name) catch return error.OutOfMemory;
    } else {
        cl.names.append(self.arena, self.arena.dupe(u8, name) catch return error.OutOfMemory) catch return error.OutOfMemory;
        cl.lower.append(self.arena, lname) catch return error.OutOfMemory;
        cl.values.append(self.arena, val) catch return error.OutOfMemory;
    }
}

fn clientSetHeader(self: *Interpreter, cl: *ClientState, this_val: Value, args: []const Value) EvalError!Completion {
    if (cl.sent) return self.throwError("Error", "Cannot set headers after they are sent to the client");
    if (args.len >= 1 and args[0] == .string)
        try clientSetHeaderRaw(self, cl, args[0].string, if (args.len > 1) args[1] else .undefined);
    return .{ .normal = this_val };
}

fn clientGetHeader(self: *Interpreter, cl: *ClientState, args: []const Value) EvalError!Completion {
    if (args.len < 1 or args[0] != .string) return .{ .normal = .undefined };
    const lname = try lowerDup(self, args[0].string);
    if (clientHeaderIndex(cl, lname)) |i| return .{ .normal = .{ .string = cl.values.items[i] } };
    return .{ .normal = .undefined };
}

fn clientRemoveHeader(self: *Interpreter, cl: *ClientState, this_val: Value, args: []const Value) EvalError!Completion {
    if (args.len < 1 or args[0] != .string) return .{ .normal = this_val };
    const lname = try lowerDup(self, args[0].string);
    if (clientHeaderIndex(cl, lname)) |i| {
        _ = cl.names.orderedRemove(i);
        _ = cl.lower.orderedRemove(i);
        _ = cl.values.orderedRemove(i);
    }
    return .{ .normal = this_val };
}

/// `req.write(chunk)` — buffer the body chunk (sent on `.end()`; the whole request is written at once).
fn clientWrite(self: *Interpreter, cl: *ClientState, _: Value, args: []const Value) EvalError!Completion {
    if (cl.sent) return .{ .normal = .{ .boolean = false } };
    const chunk = try valueToBytes(self, if (args.len > 0) args[0] else .undefined);
    cl.body.appendSlice(self.arena, chunk) catch return error.OutOfMemory;
    for (args[@min(1, args.len)..]) |a| if (a == .object and a.object.kind == .function) {
        _ = try self.callFunction(a.object, &.{}, .undefined);
    };
    return .{ .normal = .{ .boolean = true } };
}

/// `req.end([chunk])` — append the final chunk, then connect a net.Socket and (on 'connect') write the
/// full request. Idempotent.
fn clientEnd(self: *Interpreter, cl: *ClientState, this_val: Value, args: []const Value) EvalError!Completion {
    if (cl.sent) return .{ .normal = this_val };
    const chunk_v: Value = if (args.len > 0 and !(args[0] == .object and args[0].object.kind == .function)) args[0] else .undefined;
    const chunk = try valueToBytes(self, chunk_v);
    cl.body.appendSlice(self.arena, chunk) catch return error.OutOfMemory;
    cl.sent = true;
    try cl.req.set("finished", .{ .boolean = true });

    // Create the net.Socket and wire client trampolines, then connect.
    const net_mod = (try host_require.loadCoreModulePub(self, "net")).normal.object;
    const sock_ctor = net_mod.get("Socket") orelse return self.throwError("Error", "net.Socket unavailable");
    if (sock_ctor != .object) return self.throwError("Error", "net.Socket unavailable");
    const sock_c = try self.construct(sock_ctor.object, &.{});
    if (sock_c.isAbrupt()) return sock_c;
    if (sock_c.normal != .object) return self.throwError("Error", "net.Socket construction failed");
    const socket = sock_c.normal.object;
    cl.socket = socket;
    // Tie the ClientState to the socket too, so the trampolines can recover it from `this`.
    try socket.defineData(CLIENT_KEY, cl.req.get(CLIENT_KEY).?, false, false, false);

    const on_connect = try clTrampoline(self, "%clConnect%", cl.req);
    const on_data = try clTrampoline(self, "%clData%", cl.req);
    const on_end = try clTrampoline(self, "%clEnd%", cl.req);
    const on_error = try clTrampoline(self, "%clError%", cl.req);
    try jsAddListener(self, socket, "connect", .{ .object = on_connect }, true);
    try jsAddListener(self, socket, "data", .{ .object = on_data }, false);
    try jsAddListener(self, socket, "end", .{ .object = on_end }, true);
    try jsAddListener(self, socket, "close", .{ .object = on_end }, true);
    try jsAddListener(self, socket, "error", .{ .object = on_error }, false);

    // socket.connect(port, host) — drive via the JS method (mirrors host_http server-side wiring).
    const conn_v = socket.get("connect") orelse return self.throwError("Error", "socket.connect unavailable");
    if (conn_v != .object) return self.throwError("Error", "socket.connect unavailable");
    const host_arg = if (cl.hostname.len == 0) "127.0.0.1" else cl.hostname;
    const cc = try self.callFunction(conn_v.object, &.{
        .{ .number = @floatFromInt(cl.port) },
        .{ .string = try self.arena.dupe(u8, host_arg) },
    }, .{ .object = socket });
    if (cc.isAbrupt()) return cc;

    for (args[@min(1, args.len)..]) |a| if (a == .object and a.object.kind == .function) {
        _ = try self.callFunction(a.object, &.{}, .undefined);
    };
    return .{ .normal = this_val };
}

/// Make a `.http_method` trampoline bound to the ClientRequest (`%req%`).
fn clTrampoline(self: *Interpreter, native_name: []const u8, req: *Object) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .http_method, native_name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%req%", .{ .object = req }, false, false, false);
    return fn_obj;
}

fn clientOf(self: *Interpreter, func: *Object) ?*ClientState {
    const rv = func.get("%req%") orelse return null;
    if (rv != .object) return null;
    return clientStateOf(self, rv.object);
}

/// Socket 'connect': serialize the request line + headers (+ body) and write it.
fn clOnConnect(self: *Interpreter, func: *Object) EvalError!Completion {
    const cl = clientOf(self, func) orelse return .{ .normal = .undefined };
    const socket = cl.socket orelse return .{ .normal = .undefined };

    var out = std.ArrayListUnmanaged(u8).empty;
    const rl = std.fmt.allocPrint(self.arena, "{s} {s} HTTP/1.1\r\n", .{ cl.method, cl.path }) catch return error.OutOfMemory;
    out.appendSlice(self.arena, rl) catch return error.OutOfMemory;

    var have_host = false;
    var have_cl = false;
    var have_conn = false;
    for (cl.names.items, 0..) |name, i| {
        out.appendSlice(self.arena, name) catch return error.OutOfMemory;
        out.appendSlice(self.arena, ": ") catch return error.OutOfMemory;
        out.appendSlice(self.arena, cl.values.items[i]) catch return error.OutOfMemory;
        out.appendSlice(self.arena, "\r\n") catch return error.OutOfMemory;
        const l = cl.lower.items[i];
        if (std.ascii.eqlIgnoreCase(l, "host")) have_host = true;
        if (std.ascii.eqlIgnoreCase(l, "content-length")) have_cl = true;
        if (std.ascii.eqlIgnoreCase(l, "connection")) have_conn = true;
    }
    if (!have_host) {
        const h = std.fmt.allocPrint(self.arena, "Host: {s}\r\n", .{cl.host}) catch return error.OutOfMemory;
        out.appendSlice(self.arena, h) catch return error.OutOfMemory;
    }
    // Add Content-Length when there is a body and none was set (no chunked client-send this slice).
    if (!have_cl and cl.body.items.len > 0) {
        const c = std.fmt.allocPrint(self.arena, "Content-Length: {d}\r\n", .{cl.body.items.len}) catch return error.OutOfMemory;
        out.appendSlice(self.arena, c) catch return error.OutOfMemory;
    }
    if (!have_conn) out.appendSlice(self.arena, "Connection: close\r\n") catch return error.OutOfMemory;
    out.appendSlice(self.arena, "\r\n") catch return error.OutOfMemory;
    if (cl.body.items.len > 0) out.appendSlice(self.arena, cl.body.items) catch return error.OutOfMemory;

    try socketWrite(self, socket, out.items);
    return .{ .normal = .undefined };
}

/// Socket 'data': accumulate response bytes + advance the response parser.
fn clOnData(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const cl = clientOf(self, func) orelse return .{ .normal = .undefined };
    const chunk = try valueToBytes(self, if (args.len > 0) args[0] else .undefined);
    cl.in.appendSlice(self.arena, chunk) catch return error.OutOfMemory;
    try clientAdvance(self, cl);
    return .{ .normal = .undefined };
}

/// Socket 'end'/'close': a connection-close-delimited body is now complete → flush + 'end'.
fn clOnEnd(self: *Interpreter, func: *Object) EvalError!Completion {
    const cl = clientOf(self, func) orelse return .{ .normal = .undefined };
    if (cl.finished) return .{ .normal = .undefined };
    // Parse headers if not yet (a response with no body and a tiny header block could arrive in one go).
    try clientAdvance(self, cl);
    if (cl.res != null and !cl.finished) {
        if (!cl.have_content_length and !cl.chunked) {
            // read-until-close: everything after the header block is the body.
            try clientEmitRemainingBody(self, cl);
        }
        try clientFinishResponse(self, cl);
    }
    return .{ .normal = .undefined };
}

/// Socket 'error': forward to the ClientRequest as 'error'.
fn clOnError(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const cl = clientOf(self, func) orelse return .{ .normal = .undefined };
    emitSafe(self, cl.req, "error", args);
    return .{ .normal = .undefined };
}

/// Advance the response parser with whatever is buffered: parse the header block once (build the
/// response IncomingMessage + emit 'response'), then stream the body per its framing.
fn clientAdvance(self: *Interpreter, cl: *ClientState) EvalError!void {
    if (!cl.headers_done) {
        const sep = std.mem.indexOf(u8, cl.in.items, "\r\n\r\n") orelse return;
        cl.headers_done = true;
        cl.body_start = sep + 4;
        cl.chunk_offset = cl.body_start;
        try clientBuildResponse(self, cl, cl.in.items[0..sep]);
    }
    if (cl.res == null or cl.finished) return;
    if (cl.chunked) {
        try clientDecodeChunks(self, cl);
    } else if (cl.have_content_length) {
        try clientEmitContentLength(self, cl);
    }
    // read-until-close bodies stream on socket 'end' (clOnEnd).
}

/// Parse the status line + headers, build the response IncomingMessage, emit 'response'.
fn clientBuildResponse(self: *Interpreter, cl: *ClientState, header_block: []const u8) EvalError!void {
    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    const status_line = lines.next() orelse return;

    // HTTP/x.y SP code SP message
    var sl = std.mem.splitScalar(u8, status_line, ' ');
    const version_tok = sl.next() orelse "HTTP/1.1";
    const http_version = if (std.mem.startsWith(u8, version_tok, "HTTP/")) version_tok["HTTP/".len..] else "1.1";
    const code_tok = sl.next() orelse "0";
    const status_code: u16 = std.fmt.parseInt(u16, std.mem.trim(u8, code_tok, " "), 10) catch 0;
    const status_message = sl.rest(); // remainder after "HTTP/x.y CODE " (may contain spaces)

    const res_proto = try ctorProto(self, "IncomingMessage");
    const res = try Object.create(self.arena, res_proto.?);
    // Mark the response with CLIENT_KEY so setEncoding routes to the ClientState.
    try res.defineData(CLIENT_KEY, cl.req.get(CLIENT_KEY).?, false, false, false);
    const headers_obj = try Object.create(self.arena, self.objectProto());

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const raw_name = std.mem.trim(u8, line[0..colon], " \t");
        const raw_val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (raw_name.len == 0) continue;
        const lname = try lowerDup(self, raw_name);
        const val = self.arena.dupe(u8, raw_val) catch return error.OutOfMemory;
        try headers_obj.defineData(lname, .{ .string = val }, true, true, true);
        if (std.ascii.eqlIgnoreCase(lname, "content-length")) {
            cl.content_length = std.fmt.parseInt(usize, raw_val, 10) catch 0;
            cl.have_content_length = true;
        }
        if (std.ascii.eqlIgnoreCase(lname, "transfer-encoding") and
            std.ascii.indexOfIgnoreCase(raw_val, "chunked") != null)
        {
            cl.chunked = true;
        }
    }

    try res.defineData("statusCode", .{ .number = @floatFromInt(status_code) }, true, true, true);
    try res.defineData("statusMessage", .{ .string = try self.arena.dupe(u8, std.mem.trim(u8, status_message, " ")) }, true, true, true);
    try res.defineData("httpVersion", .{ .string = try self.arena.dupe(u8, http_version) }, true, true, true);
    try res.defineData("headers", .{ .object = headers_obj }, true, true, true);
    try res.defineData("complete", .{ .boolean = false }, true, true, true);
    if (cl.socket) |s| {
        try res.defineData("socket", .{ .object = s }, true, true, true);
        try res.defineData("connection", .{ .object = s }, true, true, true);
    }
    cl.res = res;
    cl.res_emitted = true;
    emitSafe(self, cl.req, "response", &.{.{ .object = res }});
}

/// Emit any newly-available Content-Length body bytes as 'data', and 'end' when complete.
fn clientEmitContentLength(self: *Interpreter, cl: *ClientState) EvalError!void {
    const res = cl.res orelse return;
    const total = cl.in.items.len;
    const have = if (total > cl.body_start) total - cl.body_start else 0;
    const want = @min(cl.content_length, have);
    if (want > cl.body_consumed) {
        const slice = cl.in.items[cl.body_start + cl.body_consumed .. cl.body_start + want];
        clientEmitData(self, cl, res, slice);
        cl.body_consumed = want;
    }
    if (cl.body_consumed >= cl.content_length) try clientFinishResponse(self, cl);
}

/// read-until-close: emit everything after the header block that hasn't been emitted yet.
fn clientEmitRemainingBody(self: *Interpreter, cl: *ClientState) EvalError!void {
    const res = cl.res orelse return;
    const total = cl.in.items.len;
    const start = cl.body_start + cl.body_consumed;
    if (total > start) {
        const slice = cl.in.items[start..total];
        clientEmitData(self, cl, res, slice);
        cl.body_consumed += slice.len;
    }
}

/// Decode `Transfer-Encoding: chunked` incrementally: `<hex-size>\r\n<data>\r\n` … `0\r\n\r\n`.
/// `chunk_offset` is the cursor; we only consume complete chunks.
fn clientDecodeChunks(self: *Interpreter, cl: *ClientState) EvalError!void {
    const res = cl.res orelse return;
    const buf = cl.in.items;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, buf, cl.chunk_offset, "\r\n") orelse return; // need full size line
        const size_line = std.mem.trim(u8, buf[cl.chunk_offset..line_end], " \t");
        // size may carry chunk-extensions after ';' — ignore them.
        const semi = std.mem.indexOfScalar(u8, size_line, ';');
        const hex = if (semi) |s| size_line[0..s] else size_line;
        const size = std.fmt.parseInt(usize, hex, 16) catch 0;
        const data_start = line_end + 2;
        if (size == 0) {
            // Last chunk; consume the trailing CRLF (and any trailers up to the blank line) if present.
            try clientFinishResponse(self, cl);
            return;
        }
        const data_end = data_start + size;
        if (data_end + 2 > buf.len) return; // need the full chunk + its trailing CRLF
        clientEmitData(self, cl, res, buf[data_start..data_end]);
        cl.chunk_offset = data_end + 2; // skip the data's trailing CRLF
    }
}

/// Emit a body slice as 'data' — a Buffer by default, or a decoded string after `res.setEncoding`.
fn clientEmitData(self: *Interpreter, cl: *ClientState, res: *Object, slice: []const u8) void {
    if (slice.len == 0) return;
    if (cl.res_encoding) |_| {
        const s = self.arena.dupe(u8, slice) catch return;
        emitSafe(self, res, "data", &.{.{ .string = s }});
    } else {
        const buf = host_buffer.makeBufferFromBytes(self, slice) catch return;
        emitSafe(self, res, "data", &.{.{ .object = buf }});
    }
}

/// Mark the response complete and emit 'end' exactly once.
fn clientFinishResponse(self: *Interpreter, cl: *ClientState) EvalError!void {
    const res = cl.res orelse return;
    if (cl.finished) return;
    cl.finished = true;
    try res.defineData("complete", .{ .boolean = true }, true, true, true);
    emitSafe(self, res, "end", &.{});
    // Close our side of the socket now that the response is fully read (Connection: close).
    if (cl.socket) |s| try socketEnd(self, s);
}

fn upperDup(self: *Interpreter, s: []const u8) EvalError![]const u8 {
    const out = self.arena.alloc(u8, s.len) catch return error.OutOfMemory;
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

// ── socket I/O helpers (drive the net Socket via its JS API) ─────────────────────────

fn socketWrite(self: *Interpreter, socket: *Object, data: []const u8) EvalError!void {
    // Fast path: queue the bytes straight to libxev (no JS `socket.write` call, no Buffer wrapping).
    // `data` is always arena-stable / static at every call site, so it outlives the async write.
    if (host_net.socketStateOf(self, socket)) |st| return host_net.writeRaw(self, st, data, false);
    const w = socket.get("write") orelse return;
    if (w != .object or w.object.kind != .function) return;
    const buf = try host_buffer.makeBufferFromBytes(self, data);
    _ = try self.callFunction(w.object, &.{.{ .object = buf }}, .{ .object = socket });
}

fn socketEnd(self: *Interpreter, socket: *Object) EvalError!void {
    if (host_net.socketStateOf(self, socket)) |st| return host_net.writeRaw(self, st, "", true);
    const e = socket.get("end") orelse return;
    if (e != .object or e.object.kind != .function) return;
    _ = try self.callFunction(e.object, &.{}, .{ .object = socket });
}

// ── misc helpers ────────────────────────────────────────────────────────────────────

/// Emit `event` on a JS EventEmitter object; an uncaught throw is reported to stderr (the loop
/// continues — a thrown handler must not abort the server).
fn emitSafe(self: *Interpreter, js: *Object, event: []const u8, extra: []const Value) void {
    const c = host_process.emitEvent(self, .{ .object = js }, event, extra) catch return;
    if (c == .throw) @import("host_timers.zig").hostReportError(self, c.throw);
}

/// Register `cb` as an `on` listener for `event` on `js` (via the JS EventEmitter `.on`).
fn jsAddListener(self: *Interpreter, js: *Object, event: []const u8, cb: Value, once: bool) EvalError!void {
    if (cb != .object or cb.object.kind != .function) return;
    const m = js.get(if (once) "once" else "on") orelse return;
    if (m != .object) return;
    _ = try self.callFunction(m.object, &.{ .{ .string = event }, cb }, .{ .object = js });
}

fn lowerDup(self: *Interpreter, s: []const u8) EvalError![]const u8 {
    const out = self.arena.alloc(u8, s.len) catch return error.OutOfMemory;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Coerce a header value (string / number / array) to its string form for emission.
fn headerValueToString(self: *Interpreter, v: Value) EvalError![]const u8 {
    if (v == .string) return self.arena.dupe(u8, v.string) catch return error.OutOfMemory;
    const sc = try self.toStringValuePub(v);
    if (sc.isAbrupt()) return "";
    return self.arena.dupe(u8, sc.normal.string) catch return error.OutOfMemory;
}

/// Extract raw bytes from a string / Buffer / Uint8Array (arena-duped). Other values stringify.
fn valueToBytes(self: *Interpreter, v: Value) EvalError![]const u8 {
    if (v == .undefined or v == .null) return "";
    if (v == .string) return self.arena.dupe(u8, v.string) catch return error.OutOfMemory;
    if (v == .object) {
        if (v.object.typed_array) |ta| {
            if (ta.buffer.array_buffer) |ab| {
                const bpe = ta.elem.bytesPerElement();
                const start = ta.byte_offset;
                const end = start + ta.array_length * bpe;
                if (end <= ab.bytes.len) return self.arena.dupe(u8, ab.bytes[start..end]) catch return error.OutOfMemory;
            }
            return "";
        }
    }
    const sc = try self.toStringValuePub(v);
    if (sc.isAbrupt()) return "";
    return self.arena.dupe(u8, sc.normal.string) catch return error.OutOfMemory;
}

/// A fixed RFC-1123 date string. We don't have a portable wall-clock formatter wired here, so emit a
/// stable placeholder (the value is informational; clients don't reject it). Good enough for v1.
fn httpDate(self: *Interpreter) []const u8 {
    _ = self;
    return "Thu, 01 Jan 1970 00:00:00 GMT";
}

/// The canonical reason phrase for common status codes (default "OK" for unknown 2xx, else generic).
fn statusText(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        410 => "Gone",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "OK",
    };
}
