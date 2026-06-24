//! qjs — a minimal Node-style HTTP runtime over the quickjs-ng engine.
//!
//! The JS *language* is quickjs-ng (real bytecode VM, UTF-16 strings, ~100% Test262). This Zig layer
//! is the *host runtime*: a **libxev** event loop (io_uring/kqueue/IOCP) driving a native HTTP/1.1
//! server that dispatches each request to a JS handler running in quickjs. It's the same architecture
//! as txiki.js / Bun — proven engine, Zig host. Enough to serve and benchmark real request loads.
//!
//! API exposed to JS:
//!   __serve(port, (method, url) => bodyString)   start the HTTP server; handler returns the body
//!   console.log(...)                             via a tiny native print (quickjs has no console)
//!
//! `qjs-run <app.js>` reads the file, evaluates it, then runs the event loop until killed.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const c = @cImport({
    @cInclude("quickjs.h");
    @cInclude("qjs_shim.h");
});

const IpAddress = std.Io.net.IpAddress;
const alloc = std.heap.c_allocator;

// ── globals shared with the libxev callbacks (single-threaded loop) ──────────────────
var g_ctx: ?*c.JSContext = null;
var g_rt: ?*c.JSRuntime = null;
var g_handler: c.JSValue = undefined;
var g_loop: xev.Loop = undefined;
var g_server_started: bool = false;

const Server = struct {
    tcp: xev.TCP,
    accept_c: xev.Completion = .{},
};
var g_server: Server = undefined;

/// Per-connection state. Allocated on accept, freed on close. `write_buf` holds the full HTTP response
/// (headers + body) so it outlives the async write without per-request heap churn.
const Conn = struct {
    tcp: xev.TCP,
    read_c: xev.Completion = .{},
    write_c: xev.Completion = .{},
    close_c: xev.Completion = .{},
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [64 * 1024]u8 = undefined,
    resp_len: usize = 0,
};

// Windows IOCP: an AcceptEx'd socket inherits nothing until SO_UPDATE_ACCEPT_CONTEXT ties it to its
// listener (else close/shutdown misbehave). No-op off Windows. (Same fix as ljs host_net.)
extern "ws2_32" fn setsockopt(s: usize, level: i32, optname: i32, optval: ?[*]const u8, optlen: i32) callconv(.winapi) i32;
fn updateAcceptContext(accepted: xev.TCP, listener: xev.TCP) void {
    if (builtin.os.tag != .windows) return;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_UPDATE_ACCEPT_CONTEXT: i32 = 28683;
    const lsock: usize = @intFromPtr(listener.fd);
    _ = setsockopt(@intFromPtr(accepted.fd), SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, std.mem.asBytes(&lsock), @sizeOf(usize));
}

fn drainJobs() void {
    const rt = g_rt orelse return;
    while (true) {
        var pctx: ?*c.JSContext = null;
        if (c.JS_ExecutePendingJob(rt, &pctx) <= 0) break;
    }
}

// ── native functions exposed to JS ───────────────────────────────────────────────────

fn jsPrint(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const n: usize = @intCast(@max(argc, 0));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var len: usize = 0;
        const s = c.JS_ToCStringLen2(ctx, &len, argv[i], false);
        if (s != null) {
            std.debug.print("{s}{s}", .{ if (i > 0) " " else "", s[0..len] });
            c.JS_FreeCString(ctx, s);
        }
    }
    std.debug.print("\n", .{});
    return c.qjs_undefined();
}

fn jsServe(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return c.qjs_undefined();
    var port: i32 = 0;
    _ = c.JS_ToInt32(ctx, &port, argv[0]);
    g_handler = c.qjs_dup(ctx, argv[1]);
    g_ctx = ctx;
    startListen(@intCast(port)) catch {
        std.debug.print("qjs: listen failed on port {d}\n", .{port});
        return c.qjs_undefined();
    };
    g_server_started = true;
    return c.qjs_undefined();
}

// ── the HTTP server (libxev) ─────────────────────────────────────────────────────────

fn startListen(port: u16) !void {
    const addr = IpAddress.parse("127.0.0.1", port) catch return error.BadAddr;
    g_server.tcp = try xev.TCP.init(addr);
    try g_server.tcp.bind(addr);
    try g_server.tcp.listen(512);
    g_server.tcp.accept(&g_loop, &g_server.accept_c, Server, &g_server, onAccept);
}

fn onAccept(ud: ?*Server, loop: *xev.Loop, _: *xev.Completion, r: xev.AcceptError!xev.TCP) xev.CallbackAction {
    const sv = ud.?;
    if (r) |client| {
        const conn = alloc.create(Conn) catch return .disarm;
        conn.* = .{ .tcp = client };
        updateAcceptContext(client, sv.tcp);
        conn.tcp.read(loop, &conn.read_c, .{ .slice = &conn.read_buf }, Conn, conn, onRead);
    } else |_| return .disarm;
    // Re-issue a FRESH accept (IOCP `.rearm` mis-handles the spent accept socket — same as ljs host_net).
    sv.tcp.accept(loop, &sv.accept_c, Server, sv, onAccept);
    return .disarm;
}

fn onRead(ud: ?*Conn, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, b: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
    const conn = ud.?;
    const n = r catch {
        conn.tcp.close(loop, &conn.close_c, Conn, conn, onClose);
        return .disarm;
    };
    if (n == 0) {
        conn.tcp.close(loop, &conn.close_c, Conn, conn, onClose);
        return .disarm;
    }
    const req = b.slice[0..n];

    // Parse the request line: METHOD SP PATH SP HTTP/1.1. (Benchmark requests arrive whole.)
    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, req, ' ')) |sp1| {
        method = req[0..sp1];
        const rest = req[sp1 + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| path = rest[0..sp2];
    }

    // Dispatch to the JS handler: handler(method, path) → body string.
    const m_val = c.JS_NewStringLen(g_ctx, method.ptr, method.len);
    const p_val = c.JS_NewStringLen(g_ctx, path.ptr, path.len);
    var call_args = [_]c.JSValue{ m_val, p_val };
    const ret = c.qjs_call(g_ctx, g_handler, 2, &call_args);
    c.qjs_free(g_ctx, m_val);
    c.qjs_free(g_ctx, p_val);

    var body_len: usize = 0;
    const body_c = c.JS_ToCStringLen2(g_ctx, &body_len, ret, false);
    const body: []const u8 = if (body_c != null) body_c[0..body_len] else "";

    // Build "HTTP/1.1 200 OK …\r\n\r\n<body>" into the connection's write buffer.
    const head = std.fmt.bufPrint(&conn.write_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{body.len}) catch "";
    const total = head.len + body.len;
    if (total <= conn.write_buf.len) {
        @memcpy(conn.write_buf[head.len..total], body);
        conn.resp_len = total;
    } else {
        conn.resp_len = head.len;
    }
    if (body_c != null) c.JS_FreeCString(g_ctx, body_c);
    c.qjs_free(g_ctx, ret);

    drainJobs(); // run any microtasks the handler queued

    conn.tcp.write(loop, &conn.write_c, .{ .slice = conn.write_buf[0..conn.resp_len] }, Conn, conn, onWrite);
    return .disarm;
}

fn onWrite(ud: ?*Conn, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const conn = ud.?;
    _ = r catch {
        conn.tcp.close(loop, &conn.close_c, Conn, conn, onClose);
        return .disarm;
    };
    // HTTP/1.1 keep-alive: read the next request on this connection.
    conn.tcp.read(loop, &conn.read_c, .{ .slice = &conn.read_buf }, Conn, conn, onRead);
    return .disarm;
}

fn onClose(ud: ?*Conn, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    alloc.destroy(ud.?);
    return .disarm;
}

// ── entry ────────────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    const rt = c.JS_NewRuntime() orelse return error.RuntimeInit;
    defer c.JS_FreeRuntime(rt);
    g_rt = rt;
    const ctx = c.JS_NewContext(rt) orelse return error.ContextInit;
    defer c.JS_FreeContext(ctx);
    g_ctx = ctx;

    g_loop = try xev.Loop.init(.{});
    defer g_loop.deinit();

    // Install globals: __serve, __print, and a minimal console.
    const global = c.JS_GetGlobalObject(ctx);
    defer c.qjs_free(ctx, global);
    _ = c.JS_SetPropertyStr(ctx, global, "__serve", c.JS_NewCFunction(ctx, jsServe, "__serve", 2));
    _ = c.JS_SetPropertyStr(ctx, global, "__print", c.JS_NewCFunction(ctx, jsPrint, "__print", 1));
    const prelude = "globalThis.console = { log: __print, error: __print, warn: __print, info: __print };\x00";
    c.qjs_free(ctx, c.JS_Eval(ctx, prelude.ptr, prelude.len - 1, "<prelude>", c.JS_EVAL_TYPE_GLOBAL));

    if (args.len < 2) {
        std.debug.print("usage: qjs-run [run] <app.js>\n", .{});
        return;
    }
    // Accept both `qjs-run <app.js>` and `qjs-run run <app.js>` (ljs-style subcommand).
    const file = if (args.len >= 3 and std.mem.eql(u8, args[1], "run")) args[2] else args[1];
    const src = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(4 * 1024 * 1024)) catch {
        std.debug.print("qjs: cannot read {s}\n", .{file});
        return;
    };
    const srcz = try arena.dupeZ(u8, src);
    const fname = try arena.dupeZ(u8, file);

    const val = c.JS_Eval(ctx, srcz.ptr, srcz.len, fname.ptr, c.JS_EVAL_TYPE_GLOBAL);
    if (c.qjs_is_exception(val) != 0) {
        const exc = c.JS_GetException(ctx);
        const es = c.JS_ToCStringLen2(ctx, null, exc, false);
        std.debug.print("Uncaught: {s}\n", .{es});
        return error.JsException;
    }
    c.qjs_free(ctx, val);
    drainJobs();

    if (g_server_started) {
        std.debug.print("qjs: http server up\n", .{});
        while (true) {
            g_loop.run(.once) catch break;
            drainJobs();
        }
    }
}
