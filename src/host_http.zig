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
//! SKIPPED (noted, not bugs): keep-alive / pipelining (every response is `Connection: close`), chunked
//! transfer-encoding (we always emit a fixed `Content-Length`), the `http.request`/`http.get` CLIENT
//! (server only — Express serving doesn't need it), `Expect: 100-continue`, trailers, HTTPS.
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

    try mod.defineData("Server", .{ .object = server_ctor }, true, false, true);
    try mod.defineData("IncomingMessage", .{ .object = req_ctor }, true, false, true);
    try mod.defineData("ServerResponse", .{ .object = res_ctor }, true, false, true);
    try defineHttpMethod(self, mod, "createServer", "createServer");

    // The internal connection trampoline — a `.http_method` native bound to a server, registered as
    // net 'connection' / socket 'data'/'end' listeners. Hidden behind `native_name`.
    try defineHttpMethod(self, mod, "%onConnection%", "%onConnection%");
    try defineHttpMethod(self, mod, "%onData%", "%onData%");
    try defineHttpMethod(self, mod, "%onEnd%", "%onEnd%");

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
    if (eq(u8, name, "Server")) return serverCtor(self, this_val, args);
    if (eq(u8, name, "IncomingMessage") or eq(u8, name, "ServerResponse")) {
        // Direct construction is allowed but uncommon; return the receiver (state attached lazily).
        return .{ .normal = if (self.native_new_target != .undefined) this_val else .undefined };
    }

    // Internal trampolines (registered as net listeners; `this_val` is the emitter that fired).
    if (eq(u8, name, "%onConnection%")) return onConnection(self, func, args);
    if (eq(u8, name, "%onData%")) return onData(self, this_val, args);
    if (eq(u8, name, "%onEnd%")) return onEnd(self, this_val);
    if (eq(u8, name, "%relay%")) return relayFire(self, func, args);

    // Instance methods — receiver must be an object.
    if (this_val != .object) return self.throwError("TypeError", "http method called on non-object");
    const js = this_val.object;

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
