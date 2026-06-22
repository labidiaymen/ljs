//! HOST runtime (Node axis, spec 107 — NOT ECMA-262): the `net` module — TCP `Socket` and `Server`,
//! backed by **libxev** (see `host_io.zig`). `require('net')` / `require('node:net')`. HOST-only:
//! never on the Test262 path (a socket can only be created from `ljs run`, which drives the loop).
//!
//! Sockets and Servers are EventEmitters (their `[[Prototype]]` chains into `%EventEmitter.prototype%`
//! from the `events` core module), so `.on`/`.once`/`.emit` resolve via the prototype chain and host
//! code emits with `host_process.emitEvent`. Per-instance native state (`*SocketState`/`*ServerState`,
//! holding the `xev.TCP` handle + completions) lives in `interp.io_handles`, keyed by a small id stored
//! as a hidden `"%io%"` own prop on the JS object.
//!
//! Loop liveness is a ref-count (`interp.io_pending`, see `host_io.pendingIo`): bumped when an op is
//! armed, dropped on its `.disarm` completion. IOCP gotchas handled here: (1) `accept`/`read` are
//! re-armed by RE-ISSUING the op and returning `.disarm` — the `.rearm` action mis-handles the spent
//! state (accept → WSAEINVAL; read → silently doesn't re-arm); (2) a socket must be created only AFTER
//! the loop exists (else AcceptEx/connect fail with EINVAL); (3) an accepted socket needs
//! `SO_UPDATE_ACCEPT_CONTEXT` before `shutdown`/graceful-close work.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_io = @import("host_io.zig");
const host_buffer = @import("host_buffer.zig");
const host_process = @import("host_process.zig");
const host_require = @import("host_require.zig");
const IpAddress = std.Io.net.IpAddress;

const IO_KEY = "%io%";

// Windows: an AcceptEx'd socket inherits NOTHING until `SO_UPDATE_ACCEPT_CONTEXT` ties it to its
// listening socket — without it `shutdown`/`getsockname`/graceful close fail or abort (RST). std's
// ws2_32 doesn't export `setsockopt`, so declare it (Windows-only; the call is a comptime no-op
// elsewhere).
extern "ws2_32" fn setsockopt(s: usize, level: i32, optname: i32, optval: ?[*]const u8, optlen: i32) callconv(.winapi) i32;

/// Tie an accepted socket to its listener (Windows IOCP requirement). No-op off Windows.
fn updateAcceptContext(accepted: xev.TCP, listener: xev.TCP) void {
    if (builtin.os.tag != .windows) return;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_UPDATE_ACCEPT_CONTEXT: i32 = 28683;
    const lsock: usize = @intFromPtr(listener.fd);
    _ = setsockopt(@intFromPtr(accepted.fd), SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, std.mem.asBytes(&lsock), @sizeOf(usize));
}

// ── per-instance native state ────────────────────────────────────────────────────

/// Native state for a TCP `Socket` (client or server-accepted). Arena-allocated (stable address) so
/// the libxev completions embedded in it stay valid for the run.
const SocketState = struct {
    interp: *Interpreter,
    js: *Object,
    // SAFETY: set in startConnect / onAccept before any read/write/shutdown uses it (guarded by has_tcp).
    tcp: xev.TCP = undefined,
    has_tcp: bool = false,
    read_c: xev.Completion = .{},
    connect_c: xev.Completion = .{},
    shutdown_c: xev.Completion = .{},
    close_c: xev.Completion = .{},
    // SAFETY: a scratch receive buffer; only the first `n` bytes (the read result) are ever read.
    read_buf: [16 * 1024]u8 = undefined,
    encoding: ?[]const u8 = null, // null → emit Buffer; set → emit decoded string
    reading: bool = false,
    paused: bool = false,
    connected: bool = false,
    remote_ended: bool = false, // peer sent EOF
    write_ended: bool = false, // we called end() / shutdown
    closed: bool = false,
    end_after_write: bool = false, // end(data): shut down once the queued write completes
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    peer: ?IpAddress = null,
    local: ?IpAddress = null,
};

/// Native state for a TCP `Server`.
const ServerState = struct {
    interp: *Interpreter,
    js: *Object,
    // SAFETY: set in startListen before bind/listen/accept use it (guarded by has_tcp).
    tcp: xev.TCP = undefined,
    has_tcp: bool = false,
    accept_c: xev.Completion = .{},
    close_c: xev.Completion = .{},
    listening: bool = false,
    closing: bool = false,
    addr: ?IpAddress = null,
    connections: u32 = 0,
};

/// A single in-flight write: its own completion + an arena copy of the payload.
const WriteCtx = struct {
    state: *SocketState,
    completion: xev.Completion = .{},
    data: []const u8,
    cb: ?*Object = null,
    end_after: bool = false,
};

// ── module construction ──────────────────────────────────────────────────────────

/// Build the `net` core-module exports: `{ Socket, Server, createServer, connect, createConnection,
/// isIP, isIPv4, isIPv6 }`. Socket/Server are constructible (`new net.Socket()`); their prototypes
/// carry the instance methods and chain into `%EventEmitter.prototype%`.
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const ee_proto = try eventEmitterProto(self);

    const mod = try Object.create(arena, self.objectProto());

    // Socket.prototype + Socket constructor.
    const socket_proto = try Object.create(arena, ee_proto);
    for ([_][2][]const u8{
        .{ "connect", "s.connect" },           .{ "write", "s.write" },
        .{ "end", "s.end" },                   .{ "setEncoding", "s.setEncoding" },
        .{ "pause", "s.pause" },               .{ "resume", "s.resume" },
        .{ "destroy", "s.destroy" },           .{ "address", "s.address" },
        .{ "setTimeout", "s.setTimeout" },     .{ "setNoDelay", "s.setNoDelay" },
        .{ "setKeepAlive", "s.setKeepAlive" }, .{ "ref", "s.ref" },
        .{ "unref", "s.unref" },
    }) |pair| try defineNetMethod(self, socket_proto, pair[0], pair[1]);
    const socket_ctor = try Object.createNative(arena, .net_method, "Socket");
    socket_ctor.prototype = self.functionProto();
    try socket_ctor.defineData("name", .{ .string = "Socket" }, false, false, true);
    try socket_ctor.defineData("prototype", .{ .object = socket_proto }, false, false, false);
    try socket_proto.defineData("constructor", .{ .object = socket_ctor }, true, false, true);

    // Server.prototype + Server constructor.
    const server_proto = try Object.create(arena, ee_proto);
    for ([_][2][]const u8{
        .{ "listen", "v.listen" },   .{ "close", "v.close" },
        .{ "address", "v.address" }, .{ "getConnections", "v.getConnections" },
        .{ "ref", "v.ref" },         .{ "unref", "v.unref" },
    }) |pair| try defineNetMethod(self, server_proto, pair[0], pair[1]);
    const server_ctor = try Object.createNative(arena, .net_method, "Server");
    server_ctor.prototype = self.functionProto();
    try server_ctor.defineData("name", .{ .string = "Server" }, false, false, true);
    try server_ctor.defineData("prototype", .{ .object = server_proto }, false, false, false);
    try server_proto.defineData("constructor", .{ .object = server_ctor }, true, false, true);

    try mod.defineData("Socket", .{ .object = socket_ctor }, true, false, true);
    try mod.defineData("Stream", .{ .object = socket_ctor }, true, false, true); // legacy alias
    try mod.defineData("Server", .{ .object = server_ctor }, true, false, true);
    for ([_][]const u8{ "createServer", "connect", "createConnection", "isIP", "isIPv4", "isIPv6" }) |m|
        try defineNetMethod(self, mod, m, m);
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

fn defineNetMethod(self: *Interpreter, target: *Object, key: []const u8, native_name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .net_method, native_name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = key }, false, false, true);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

// ── dispatch ─────────────────────────────────────────────────────────────────────

/// Dispatch a `.net_method` native by `func.native_name`. Statics are unprefixed; Socket instance
/// methods are `s.*`; Server instance methods are `v.*`.
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;

    // ── statics ──
    if (eq(u8, name, "isIP")) return .{ .normal = .{ .number = @floatFromInt(classifyIp(args)) } };
    if (eq(u8, name, "isIPv4")) return .{ .normal = .{ .boolean = classifyIp(args) == 4 } };
    if (eq(u8, name, "isIPv6")) return .{ .normal = .{ .boolean = classifyIp(args) == 6 } };
    if (eq(u8, name, "createServer")) return createServer(self, args);
    if (eq(u8, name, "connect") or eq(u8, name, "createConnection")) return connect(self, args);
    if (eq(u8, name, "Socket")) return socketCtor(self, this_val);
    if (eq(u8, name, "Server")) return serverCtor(self, this_val, args);

    // ── instance methods ──
    if (this_val != .object) return self.throwError("TypeError", "net method called on non-object");
    const js = this_val.object;
    if (std.mem.startsWith(u8, name, "s.")) return socketMethod(self, js, name[2..], this_val, args);
    if (std.mem.startsWith(u8, name, "v.")) return serverMethod(self, js, name[2..], this_val, args);
    return .{ .normal = .undefined };
}

// ── isIP ─────────────────────────────────────────────────────────────────────────

/// Node `net.isIP(input)` → 4 / 6 / 0. Pure parse, no I/O.
fn classifyIp(args: []const Value) u8 {
    const v = if (args.len > 0) args[0] else .undefined;
    const s = if (v == .string) v.string else return 0;
    if (IpAddress.parseIp4(s, 0)) |_| return 4 else |_| {}
    if (IpAddress.parseIp6(s, 0)) |_| return 6 else |_| {}
    return 0;
}

// ── handle registry ──────────────────────────────────────────────────────────────

fn registerHandle(self: *Interpreter, js: *Object, ptr: *anyopaque) EvalError!void {
    const id = self.next_io_id;
    self.next_io_id += 1;
    self.io_handles.put(self.arena, id, ptr) catch return error.OutOfMemory;
    try js.defineData(IO_KEY, .{ .number = @floatFromInt(id) }, false, false, false);
}

fn handlePtr(self: *Interpreter, js: *Object) ?*anyopaque {
    const v = js.get(IO_KEY) orelse return null;
    if (v != .number) return null;
    const id: u64 = @intFromFloat(v.number);
    return self.io_handles.get(id);
}

pub fn socketStateOf(self: *Interpreter, js: *Object) ?*SocketState {
    const p = handlePtr(self, js) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// PERF: queue a raw-bytes write straight to the libxev TCP, bypassing the JS `socket.write` method
/// (no property lookup / callFunction / Buffer wrapping). `bytes` must outlive the async write
/// (arena-allocated). Used by `http` on the hot response path. `end_after` shuts down once it completes.
pub fn writeRaw(self: *Interpreter, st: *SocketState, bytes: []const u8, end_after: bool) EvalError!void {
    if (!st.has_tcp or st.closed) {
        if (end_after) doShutdown(st);
        return;
    }
    if (bytes.len == 0) {
        if (end_after) {
            st.write_ended = true;
            doShutdown(st);
        }
        return;
    }
    const wc = self.arena.create(WriteCtx) catch return error.OutOfMemory;
    wc.* = .{ .state = st, .data = bytes, .cb = null, .end_after = end_after };
    const loop = try host_io.ensureLoop(self);
    self.io_pending += 1;
    st.tcp.write(loop, &wc.completion, .{ .slice = wc.data }, WriteCtx, wc, onWrite);
}

fn serverStateOf(self: *Interpreter, js: *Object) ?*ServerState {
    const p = handlePtr(self, js) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Create a fresh JS Socket object (proto = `net.Socket.prototype`) with attached `SocketState`.
fn newSocketObject(self: *Interpreter) EvalError!*SocketState {
    const net_mod = (try host_require.loadCoreModulePub(self, "net")).normal.object;
    const proto = blk: {
        if (net_mod.get("Socket")) |sc| if (sc == .object)
            if (sc.object.get("prototype")) |p| if (p == .object) break :blk p.object;
        break :blk self.objectProto();
    };
    const js = try Object.create(self.arena, proto);
    const st = self.arena.create(SocketState) catch return error.OutOfMemory;
    st.* = .{ .interp = self, .js = js };
    try registerHandle(self, js, st);
    return st;
}

// ── constructors ─────────────────────────────────────────────────────────────────

fn socketCtor(self: *Interpreter, this_val: Value) EvalError!Completion {
    if (self.native_new_target != .undefined and this_val == .object) {
        const st = self.arena.create(SocketState) catch return error.OutOfMemory;
        st.* = .{ .interp = self, .js = this_val.object };
        try registerHandle(self, this_val.object, st);
        return .{ .normal = this_val };
    }
    return .{ .normal = .undefined };
}

fn serverCtor(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target != .undefined and this_val == .object) {
        const st = self.arena.create(ServerState) catch return error.OutOfMemory;
        st.* = .{ .interp = self, .js = this_val.object };
        try registerHandle(self, this_val.object, st);
        try addConnectionListener(self, this_val.object, args);
        return .{ .normal = this_val };
    }
    return .{ .normal = .undefined };
}

// ── helpers: emit, listeners, arg parsing ────────────────────────────────────────

/// Emit `event` on a Socket/Server JS object; an uncaught throw (e.g. 'error' with no listener) is
/// reported to stderr (the loop continues). Safe to call from a libxev callback.
fn emitSafe(st_interp: *Interpreter, js: *Object, event: []const u8, extra: []const Value) void {
    const c = host_process.emitEvent(st_interp, .{ .object = js }, event, extra) catch return;
    if (c == .throw) @import("host_timers.zig").hostReportError(st_interp, c.throw);
}

/// Register `cb` as an `on`/`once` listener for `event` by calling the JS method (so the standard
/// EventEmitter store is used). No-op if `cb` isn't callable.
fn jsAddListener(self: *Interpreter, js: *Object, event: []const u8, cb: Value, once: bool) EvalError!void {
    if (cb != .object or cb.object.kind != .function) return;
    const m = js.get(if (once) "once" else "on") orelse return;
    if (m != .object) return;
    _ = try self.callFunction(m.object, &.{ .{ .string = event }, cb }, .{ .object = js });
}

fn addConnectionListener(self: *Interpreter, js: *Object, args: []const Value) EvalError!void {
    // createServer([options,] [connectionListener]) — the listener is the last function argument.
    var cb: Value = .undefined;
    for (args) |a| if (a == .object and a.object.kind == .function) {
        cb = a;
    };
    try jsAddListener(self, js, "connection", cb, false);
}

/// Resolve a host string + port to an IpAddress. "localhost"/empty → 127.0.0.1; numeric IPv4/IPv6
/// parsed directly. Returns null on an unparseable hostname (DNS resolution is out of scope).
fn resolveAddr(host: []const u8, port: u16) ?IpAddress {
    const h = if (host.len == 0 or std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    return IpAddress.parse(h, port) catch null;
}

const ConnArgs = struct { port: u16, host: []const u8, cb: Value };

/// Parse `connect(port[,host][,cb])` / `connect(options[,cb])` / `listen(port[,host][,cb])`.
fn parseConnArgs(self: *Interpreter, args: []const Value) EvalError!ConnArgs {
    var out = ConnArgs{ .port = 0, .host = "", .cb = .undefined };
    if (args.len == 0) return out;
    if (args[0] == .object and args[0].object.kind != .function) {
        // options object { port, host }
        const o = args[0].object;
        if (o.get("port")) |pv| {
            const n = try self.toNumberV(pv);
            if (!n.isAbrupt()) out.port = numToPort(n.normal.number);
        }
        if (o.get("host")) |hv| if (hv == .string) {
            out.host = hv.string;
        };
    } else {
        const n = try self.toNumberV(args[0]);
        if (!n.isAbrupt()) out.port = numToPort(n.normal.number);
    }
    // trailing host string / callback
    for (args[1..]) |a| {
        if (a == .string) {
            out.host = a.string;
        } else if (a == .object and a.object.kind == .function) {
            out.cb = a;
        }
    }
    return out;
}

fn numToPort(n: f64) u16 {
    if (std.math.isNan(n) or n < 0 or n > 65535) return 0;
    return @intFromFloat(n);
}

// ── client connect ───────────────────────────────────────────────────────────────

fn connect(self: *Interpreter, args: []const Value) EvalError!Completion {
    const st = try newSocketObject(self);
    const ca = try parseConnArgs(self, args);
    if (ca.cb != .undefined) try jsAddListener(self, st.js, "connect", ca.cb, true);
    try startConnect(self, st, ca);
    return .{ .normal = .{ .object = st.js } };
}

fn startConnect(self: *Interpreter, st: *SocketState, ca: ConnArgs) EvalError!void {
    const addr = resolveAddr(ca.host, ca.port) orelse {
        emitSafe(self, st.js, "error", &.{try makeError(self, "ENOTFOUND", "getaddrinfo ENOTFOUND")});
        return;
    };
    // The loop must exist BEFORE any socket is created (Windows/IOCP: a socket made before the
    // completion port leads AcceptEx/connect to fail with WSAEINVAL).
    const loop = try host_io.ensureLoop(self);
    st.tcp = xev.TCP.init(addr) catch {
        emitSafe(self, st.js, "error", &.{try makeError(self, "EADDRNOTAVAIL", "connect failed")});
        return;
    };
    st.has_tcp = true;
    st.peer = addr;
    self.io_pending += 1;
    st.tcp.connect(loop, &st.connect_c, addr, SocketState, st, onConnect);
}

fn onConnect(ud: ?*SocketState, _: *xev.Loop, _: *xev.Completion, s: xev.TCP, r: xev.ConnectError!void) xev.CallbackAction {
    const st = ud.?;
    st.interp.io_pending -= 1;
    if (r) |_| {
        st.tcp = s;
        st.connected = true;
        emitSafe(st.interp, st.js, "connect", &.{});
        emitSafe(st.interp, st.js, "ready", &.{});
        startRead(st);
    } else |_| {
        emitSafe(st.interp, st.js, "error", &.{makeError(st.interp, "ECONNREFUSED", "connect ECONNREFUSED") catch .undefined});
    }
    return .disarm;
}

// ── read pump ────────────────────────────────────────────────────────────────────

fn startRead(st: *SocketState) void {
    if (st.paused or st.reading or st.remote_ended or st.closed or !st.has_tcp) return;
    const loop = host_io.maybeLoop(st.interp) orelse return;
    st.reading = true;
    st.interp.io_pending += 1;
    st.tcp.read(loop, &st.read_c, .{ .slice = &st.read_buf }, SocketState, st, onRead);
}

fn onRead(ud: ?*SocketState, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, b: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
    const st = ud.?;
    if (r) |n| {
        st.bytes_read += n;
        const data = b.slice[0..n];
        deliverData(st, data);
        // Re-issue a FRESH read unless paused/closed by a listener during delivery. (IOCP's `.rearm`
        // on a recv is unreliable — same class of bug as accept — so we re-issue and `.disarm`; the
        // re-issue inherits this read's ref, so `io_pending` is unchanged.)
        if (!st.paused and !st.remote_ended and !st.closed) {
            if (host_io.maybeLoop(st.interp)) |loop| {
                st.tcp.read(loop, &st.read_c, .{ .slice = &st.read_buf }, SocketState, st, onRead);
                return .disarm;
            }
        }
        st.reading = false;
        st.interp.io_pending -= 1;
        return .disarm;
    } else |err| {
        st.reading = false;
        st.interp.io_pending -= 1;
        if (err == error.EOF) {
            st.remote_ended = true;
            emitSafe(st.interp, st.js, "end", &.{});
            maybeClose(st);
        } else if (err != error.Canceled) {
            emitSafe(st.interp, st.js, "error", &.{makeError(st.interp, "ECONNRESET", "read ECONNRESET") catch .undefined});
            doClose(st);
        }
        return .disarm;
    }
}

/// Emit 'data' with the received bytes as a Buffer (default) or a decoded string (after setEncoding).
fn deliverData(st: *SocketState, data: []const u8) void {
    const self = st.interp;
    if (st.encoding) |_| {
        // Minimal: treat the configured encoding as UTF-8/latin1 bytes-as-string.
        const s = self.arena.dupe(u8, data) catch return;
        emitSafe(self, st.js, "data", &.{.{ .string = s }});
    } else {
        const buf = host_buffer.makeBufferFromBytes(self, data) catch return;
        emitSafe(self, st.js, "data", &.{.{ .object = buf }});
    }
}

// ── write / end ──────────────────────────────────────────────────────────────────

fn socketWrite(self: *Interpreter, st: *SocketState, args: []const Value, end_after: bool) EvalError!Completion {
    const data_v: Value = if (args.len > 0) args[0] else .undefined;
    var cb: Value = .undefined;
    for (args[@min(1, args.len)..]) |a|
        if (a == .object and a.object.kind == .function) {
            cb = a;
        };
    const bytes = try valueToBytes(self, data_v);
    if (!st.has_tcp or st.closed) {
        if (end_after) doShutdown(st);
        return .{ .normal = .{ .boolean = true } };
    }
    if (bytes.len == 0) {
        if (cb != .undefined) _ = try self.callFunction(cb.object, &.{}, .undefined);
        if (end_after) {
            st.write_ended = true;
            doShutdown(st);
        }
        return .{ .normal = .{ .boolean = true } };
    }
    const wc = self.arena.create(WriteCtx) catch return error.OutOfMemory;
    wc.* = .{ .state = st, .data = bytes, .cb = if (cb == .object) cb.object else null, .end_after = end_after };
    const loop = try host_io.ensureLoop(self);
    self.io_pending += 1;
    st.tcp.write(loop, &wc.completion, .{ .slice = wc.data }, WriteCtx, wc, onWrite);
    return .{ .normal = .{ .boolean = true } };
}

fn onWrite(ud: ?*WriteCtx, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const wc = ud.?;
    const st = wc.state;
    st.interp.io_pending -= 1;
    if (r) |n| {
        st.bytes_written += n;
    } else |_| {
        emitSafe(st.interp, st.js, "error", &.{makeError(st.interp, "EPIPE", "write EPIPE") catch .undefined});
    }
    if (wc.cb) |cbf| {
        // The write callback is best-effort; an EvalError (e.g. OOM) recovers to a no-op completion.
        _ = st.interp.callFunction(cbf, &.{}, .undefined) catch Completion{ .normal = .undefined };
    }
    if (wc.end_after) {
        st.write_ended = true;
        doShutdown(st);
    }
    return .disarm;
}

/// `end()` writable-side teardown: half-close via TCP `shutdown` (sends FIN; the peer reads EOF). The
/// readable side stays open until the peer also ends (then `maybeClose` closes). Accepted sockets need
/// `SO_UPDATE_ACCEPT_CONTEXT` first (done in `onAccept`) for shutdown to succeed on Windows.
fn doShutdown(st: *SocketState) void {
    if (!st.has_tcp or st.closed) {
        st.write_ended = true;
        maybeClose(st);
        return;
    }
    const loop = host_io.maybeLoop(st.interp) orelse return;
    st.interp.io_pending += 1;
    st.tcp.shutdown(loop, &st.shutdown_c, SocketState, st, onShutdown);
}

fn onShutdown(ud: ?*SocketState, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, r: xev.ShutdownError!void) xev.CallbackAction {
    const st = ud.?;
    st.interp.io_pending -= 1;
    st.write_ended = true;
    emitSafe(st.interp, st.js, "finish", &.{});
    // If shutdown failed, fall back to a full close so the peer still observes EOF.
    if (r) |_| maybeClose(st) else |_| doClose(st);
    return .disarm;
}

/// Close the socket once both directions are done (peer EOF + our end).
fn maybeClose(st: *SocketState) void {
    if (st.closed) return;
    if (st.remote_ended and st.write_ended) doClose(st);
}

fn doClose(st: *SocketState) void {
    if (st.closed or !st.has_tcp) {
        if (!st.closed) {
            st.closed = true;
            emitSafe(st.interp, st.js, "close", &.{.{ .boolean = false }});
        }
        return;
    }
    st.closed = true;
    const loop = host_io.maybeLoop(st.interp) orelse return;
    st.interp.io_pending += 1;
    st.tcp.close(loop, &st.close_c, SocketState, st, onSocketClose);
}

fn onSocketClose(ud: ?*SocketState, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    const st = ud.?;
    st.interp.io_pending -= 1;
    st.has_tcp = false;
    emitSafe(st.interp, st.js, "close", &.{.{ .boolean = false }});
    return .disarm;
}

// ── socket instance methods ──────────────────────────────────────────────────────

fn socketMethod(self: *Interpreter, js: *Object, m: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    const st = socketStateOf(self, js) orelse return .{ .normal = this_val };
    if (eq(u8, m, "connect")) {
        const ca = try parseConnArgs(self, args);
        if (ca.cb != .undefined) try jsAddListener(self, js, "connect", ca.cb, true);
        try startConnect(self, st, ca);
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "write")) return socketWrite(self, st, args, false);
    if (eq(u8, m, "end")) {
        if (args.len > 0 and args[0] != .undefined and !(args[0] == .object and args[0].object.kind == .function)) {
            _ = try socketWrite(self, st, args, true);
        } else {
            st.write_ended = true;
            doShutdown(st);
        }
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "setEncoding")) {
        if (args.len > 0 and args[0] == .string) st.encoding = self.arena.dupe(u8, args[0].string) catch null else st.encoding = null;
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "pause")) {
        st.paused = true;
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "resume")) {
        st.paused = false;
        startRead(st);
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "destroy")) {
        doClose(st);
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "address")) return .{ .normal = .{ .object = try addressObject(self, st.local orelse st.peer) } };
    // setTimeout/setNoDelay/setKeepAlive/ref/unref — accept and (mostly) no-op this cycle.
    if (eq(u8, m, "setTimeout")) {
        if (args.len > 1) try jsAddListener(self, js, "timeout", args[1], true);
        return .{ .normal = this_val };
    }
    return .{ .normal = this_val };
}

// ── server methods ───────────────────────────────────────────────────────────────

fn createServer(self: *Interpreter, args: []const Value) EvalError!Completion {
    const net_mod = (try host_require.loadCoreModulePub(self, "net")).normal.object;
    const proto = blk: {
        if (net_mod.get("Server")) |sc| if (sc == .object)
            if (sc.object.get("prototype")) |p| if (p == .object) break :blk p.object;
        break :blk self.objectProto();
    };
    const js = try Object.create(self.arena, proto);
    const st = self.arena.create(ServerState) catch return error.OutOfMemory;
    st.* = .{ .interp = self, .js = js };
    try registerHandle(self, js, st);
    try addConnectionListener(self, js, args);
    return .{ .normal = .{ .object = js } };
}

fn serverMethod(self: *Interpreter, js: *Object, m: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    const st = serverStateOf(self, js) orelse return .{ .normal = this_val };
    if (eq(u8, m, "listen")) {
        const ca = try parseConnArgs(self, args);
        if (ca.cb != .undefined) try jsAddListener(self, js, "listening", ca.cb, true);
        try startListen(self, st, ca);
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "close")) {
        if (args.len > 0 and args[0] == .object and args[0].object.kind == .function)
            try jsAddListener(self, js, "close", args[0], true);
        serverClose(st);
        return .{ .normal = this_val };
    }
    if (eq(u8, m, "address")) {
        if (!st.listening) return .{ .normal = .null };
        return .{ .normal = .{ .object = try addressObject(self, st.addr) } };
    }
    if (eq(u8, m, "getConnections")) {
        if (args.len > 0 and args[0] == .object and args[0].object.kind == .function)
            _ = try self.callFunction(args[0].object, &.{ .null, .{ .number = @floatFromInt(st.connections) } }, .undefined);
        return .{ .normal = this_val };
    }
    return .{ .normal = this_val };
}

fn startListen(self: *Interpreter, st: *ServerState, ca: ConnArgs) EvalError!void {
    const addr = resolveAddr(ca.host, ca.port) orelse {
        emitSafe(self, st.js, "error", &.{try makeError(self, "EADDRNOTAVAIL", "bind EADDRNOTAVAIL")});
        return;
    };
    // The loop must exist BEFORE the listening socket is created (Windows/IOCP: AcceptEx on a socket
    // created before the completion port fails with WSAEINVAL).
    const loop = try host_io.ensureLoop(self);
    st.tcp = xev.TCP.init(addr) catch {
        emitSafe(self, st.js, "error", &.{try makeError(self, "EADDRINUSE", "listen failed")});
        return;
    };
    st.has_tcp = true;
    st.tcp.bind(addr) catch {
        emitSafe(self, st.js, "error", &.{try makeError(self, "EADDRINUSE", "listen EADDRINUSE")});
        return;
    };
    st.tcp.listen(128) catch {
        emitSafe(self, st.js, "error", &.{try makeError(self, "EADDRINUSE", "listen EADDRINUSE")});
        return;
    };
    st.addr = addr;
    st.listening = true;
    self.io_pending += 1;
    st.tcp.accept(loop, &st.accept_c, ServerState, st, onAccept);
    emitSafe(self, st.js, "listening", &.{});
}

fn onAccept(ud: ?*ServerState, _: *xev.Loop, _: *xev.Completion, r: xev.AcceptError!xev.TCP) xev.CallbackAction {
    const sv = ud.?;
    if (r) |client_tcp| {
        // Build a server-side Socket for the accepted connection.
        const st = newSocketObject(sv.interp) catch {
            // Could not allocate — stop accepting (drop the accept ref).
            sv.interp.io_pending -= 1;
            return .disarm;
        };
        st.tcp = client_tcp;
        st.has_tcp = true;
        st.connected = true;
        updateAcceptContext(client_tcp, sv.tcp); // Windows: required before shutdown/close behave
        sv.connections += 1;
        emitSafe(sv.interp, sv.js, "connection", &.{.{ .object = st.js }});
        startRead(st);
    } else |_| {
        // Canceled (server.close) or a transient error: stop accepting.
        sv.interp.io_pending -= 1;
        finishServerClose(sv);
        return .disarm;
    }
    // Re-arm a FRESH accept. IOCP's `.rearm` reuses the spent `internal_accept_socket` (→ WSAEINVAL),
    // so we re-issue accept on the same completion (which `accept()` re-initializes) and `.disarm` the
    // fired one. The re-issue inherits this completion's ref, so `io_pending` is unchanged — exactly
    // one accept stays in flight.
    if (sv.closing) {
        sv.interp.io_pending -= 1;
        return .disarm;
    }
    const loop = host_io.maybeLoop(sv.interp) orelse {
        sv.interp.io_pending -= 1;
        return .disarm;
    };
    sv.tcp.accept(loop, &sv.accept_c, ServerState, sv, onAccept);
    return .disarm;
}

fn serverClose(st: *ServerState) void {
    if (st.closing or !st.listening) return;
    st.closing = true;
    if (!st.has_tcp) {
        finishServerClose(st);
        return;
    }
    // Closing the listening socket cancels the pending accept (its callback fires with Canceled).
    const loop = host_io.maybeLoop(st.interp) orelse return;
    st.interp.io_pending += 1;
    st.tcp.close(loop, &st.close_c, ServerState, st, onServerClose);
}

fn onServerClose(ud: ?*ServerState, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    const st = ud.?;
    st.interp.io_pending -= 1;
    st.has_tcp = false;
    finishServerClose(st);
    return .disarm;
}

fn finishServerClose(st: *ServerState) void {
    if (!st.listening) return;
    st.listening = false;
    emitSafe(st.interp, st.js, "close", &.{});
}

// ── address / error helpers ──────────────────────────────────────────────────────

fn addressObject(self: *Interpreter, addr: ?IpAddress) EvalError!*Object {
    const o = try Object.create(self.arena, self.objectProto());
    if (addr) |a| switch (a) {
        .ip4 => |v4| {
            const s = std.fmt.allocPrint(self.arena, "{d}.{d}.{d}.{d}", .{ v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3] }) catch return error.OutOfMemory;
            try o.defineData("address", .{ .string = s }, true, true, true);
            try o.defineData("family", .{ .string = "IPv4" }, true, true, true);
            try o.defineData("port", .{ .number = @floatFromInt(v4.port) }, true, true, true);
        },
        .ip6 => |v6| {
            try o.defineData("address", .{ .string = "::" }, true, true, true);
            try o.defineData("family", .{ .string = "IPv6" }, true, true, true);
            try o.defineData("port", .{ .number = @floatFromInt(v6.port) }, true, true, true);
        },
    } else {
        try o.defineData("address", .{ .string = "0.0.0.0" }, true, true, true);
        try o.defineData("family", .{ .string = "IPv4" }, true, true, true);
        try o.defineData("port", .{ .number = 0 }, true, true, true);
    }
    return o;
}

/// A Node-style Error object value (not thrown) carrying a `code` property.
fn makeError(self: *Interpreter, code: []const u8, message: []const u8) EvalError!Value {
    const err = try Object.create(self.arena, self.errorProto("Error"));
    err.error_data = true;
    try err.set("name", .{ .string = "Error" });
    try err.set("message", .{ .string = message });
    try err.set("code", .{ .string = code });
    return .{ .object = err };
}

/// Extract the raw bytes from a string / Buffer / Uint8Array argument (arena-duped so the caller may
/// retain them across the async write). Non-buffer-like values stringify.
fn valueToBytes(self: *Interpreter, v: Value) EvalError![]const u8 {
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
