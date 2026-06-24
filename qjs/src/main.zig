//! qjs — a Node-style HTTP runtime over the quickjs-ng engine.
//!
//! The JS *language* is quickjs-ng (real bytecode VM, UTF-16 strings, ~100% Test262). This Zig layer
//! is the *host runtime*: a **libxev** event loop driving a native HTTP/1.1 server. A small set of
//! native primitives is exposed to JS, and the bulk of the Node-compat surface (`http` req/res,
//! `EventEmitter`, `require`, core modules) lives in `bootstrap.js`, evaluated at startup — the same
//! "native primitives + JS standard library" split Node itself uses.
//!
//! Native primitives:
//!   __serve(port)                       start the HTTP listener
//!   __respond(id, status, headers, body) write the response for in-flight request `id`
//!   __readFile(path) -> string|null     read a file (for `require`)
//!   __print(...)                        console
//! Native → JS:  globalThis.__dispatch(id, method, url, rawHeaders)  per request.
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
var g_dispatch: c.JSValue = undefined; // globalThis.__dispatch (owned)
var g_loop: xev.Loop = undefined;
var g_io: std.Io = undefined;
var g_server_started: bool = false;

var g_conns: std.AutoHashMapUnmanaged(u32, *Conn) = .empty;
var g_next_id: u32 = 1;

const Server = struct {
    tcp: xev.TCP,
    accept_c: xev.Completion = .{},
};
var g_server: Server = undefined;

/// Per-connection state. Allocated on accept, freed on close. `write_buf` holds the full HTTP response.
const Conn = struct {
    tcp: xev.TCP,
    read_c: xev.Completion = .{},
    write_c: xev.Completion = .{},
    close_c: xev.Completion = .{},
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [64 * 1024]u8 = undefined,
    resp_len: usize = 0,
};

// Windows IOCP: tie an accepted socket to its listener (SO_UPDATE_ACCEPT_CONTEXT). No-op elsewhere.
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

fn reportIfException(val: c.JSValue) void {
    if (c.qjs_is_exception(val) == 0) return;
    const exc = c.JS_GetException(g_ctx);
    const es = c.JS_ToCStringLen2(g_ctx, null, exc, false);
    std.debug.print("qjs uncaught: {s}\n", .{es});
    if (es != null) c.JS_FreeCString(g_ctx, es);
    const stk = c.JS_GetPropertyStr(g_ctx, exc, "stack");
    if (c.qjs_is_exception(stk) == 0) {
        const ss = c.JS_ToCStringLen2(g_ctx, null, stk, false);
        if (ss != null) {
            std.debug.print("{s}\n", .{ss});
            c.JS_FreeCString(g_ctx, ss);
        }
    }
    c.qjs_free(g_ctx, stk);
    c.qjs_free(g_ctx, exc);
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

fn jsReadFile(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.qjs_null();
    var plen: usize = 0;
    const pc = c.JS_ToCStringLen2(ctx, &plen, argv[0], false);
    if (pc == null) return c.qjs_null();
    defer c.JS_FreeCString(ctx, pc);
    const path = pc[0..plen];
    const data = std.Io.Dir.cwd().readFileAlloc(g_io, path, alloc, .limited(8 * 1024 * 1024)) catch return c.qjs_null();
    defer alloc.free(data);
    return c.JS_NewStringLen(ctx, data.ptr, data.len);
}

fn jsServe(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.qjs_undefined();
    var port: i32 = 0;
    _ = c.JS_ToInt32(ctx, &port, argv[0]);
    g_ctx = ctx;
    const g = c.JS_GetGlobalObject(ctx);
    g_dispatch = c.JS_GetPropertyStr(ctx, g, "__dispatch");
    c.qjs_free(ctx, g);
    startListen(@intCast(port)) catch {
        std.debug.print("qjs: listen failed on port {d}\n", .{port});
        return c.qjs_undefined();
    };
    g_server_started = true;
    return c.qjs_undefined();
}

fn reasonPhrase(code: i32) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "OK",
    };
}

fn jsRespond(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return c.qjs_undefined();
    var id: i32 = 0;
    _ = c.JS_ToInt32(ctx, &id, argv[0]);
    var status: i32 = 200;
    _ = c.JS_ToInt32(ctx, &status, argv[1]);
    var hlen: usize = 0;
    const hc = c.JS_ToCStringLen2(ctx, &hlen, argv[2], false);
    var blen: usize = 0;
    const bc = c.JS_ToCStringLen2(ctx, &blen, argv[3], false);
    const hdrs: []const u8 = if (hc != null) hc[0..hlen] else "";
    const body: []const u8 = if (bc != null) bc[0..blen] else "";

    if (g_conns.get(@intCast(id))) |co| {
        _ = g_conns.remove(@intCast(id));
        const head = std.fmt.bufPrint(&co.write_buf, "HTTP/1.1 {d} {s}\r\n{s}Content-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{ status, reasonPhrase(status), hdrs, body.len }) catch "";
        const total = head.len + body.len;
        if (total <= co.write_buf.len) {
            @memcpy(co.write_buf[head.len..total], body);
            co.resp_len = total;
        } else co.resp_len = head.len;
        co.tcp.write(&g_loop, &co.write_c, .{ .slice = co.write_buf[0..co.resp_len] }, Conn, co, onWrite);
    }
    if (hc != null) c.JS_FreeCString(ctx, hc);
    if (bc != null) c.JS_FreeCString(ctx, bc);
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

    // Request line: METHOD SP URL SP HTTP/1.1\r\n ; then the header block up to \r\n\r\n.
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
    const line = req[0..line_end];
    var method: []const u8 = "GET";
    var url: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, line, ' ')) |sp1| {
        method = line[0..sp1];
        const rest = line[sp1 + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| url = rest[0..sp2];
    }
    var headers: []const u8 = "";
    if (std.mem.indexOf(u8, req, "\r\n\r\n")) |he| {
        if (line_end + 2 <= he) headers = req[line_end + 2 .. he];
    }

    const id = g_next_id;
    g_next_id +%= 1;
    if (g_next_id == 0) g_next_id = 1;
    g_conns.put(alloc, id, conn) catch {
        conn.tcp.close(loop, &conn.close_c, Conn, conn, onClose);
        return .disarm;
    };

    // Dispatch to JS: __dispatch(id, method, url, rawHeaders). The handler calls __respond (sync or
    // async); we do NOT re-arm read here — onWrite re-arms after the response goes out (keep-alive).
    const idv = c.qjs_int(g_ctx, @intCast(id));
    const mv = c.JS_NewStringLen(g_ctx, method.ptr, method.len);
    const uv = c.JS_NewStringLen(g_ctx, url.ptr, url.len);
    const hv = c.JS_NewStringLen(g_ctx, headers.ptr, headers.len);
    var call_args = [_]c.JSValue{ idv, mv, uv, hv };
    const ret = c.qjs_call(g_ctx, g_dispatch, 4, &call_args);
    reportIfException(ret);
    c.qjs_free(g_ctx, ret);
    c.qjs_free(g_ctx, idv);
    c.qjs_free(g_ctx, mv);
    c.qjs_free(g_ctx, uv);
    c.qjs_free(g_ctx, hv);
    drainJobs();
    return .disarm;
}

fn onWrite(ud: ?*Conn, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const conn = ud.?;
    _ = r catch {
        conn.tcp.close(loop, &conn.close_c, Conn, conn, onClose);
        return .disarm;
    };
    conn.tcp.read(loop, &conn.read_c, .{ .slice = &conn.read_buf }, Conn, conn, onRead);
    return .disarm;
}

fn onClose(ud: ?*Conn, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    alloc.destroy(ud.?);
    return .disarm;
}

// ── entry ────────────────────────────────────────────────────────────────────────────

fn installFn(ctx: ?*c.JSContext, global: c.JSValue, name: [*c]const u8, func: c.JSCFunction, argc: c_int) void {
    _ = c.JS_SetPropertyStr(ctx, global, name, c.JS_NewCFunction(ctx, func, name, argc));
}

const bootstrap_src = @embedFile("bootstrap.js");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    g_io = init.io;

    const rt = c.JS_NewRuntime() orelse return error.RuntimeInit;
    defer c.JS_FreeRuntime(rt);
    g_rt = rt;
    const ctx = c.JS_NewContext(rt) orelse return error.ContextInit;
    defer c.JS_FreeContext(ctx);
    g_ctx = ctx;

    g_loop = try xev.Loop.init(.{});
    defer g_loop.deinit();

    const global = c.JS_GetGlobalObject(ctx);
    defer c.qjs_free(ctx, global);
    installFn(ctx, global, "__serve", jsServe, 1);
    installFn(ctx, global, "__respond", jsRespond, 4);
    installFn(ctx, global, "__readFile", jsReadFile, 1);
    installFn(ctx, global, "__print", jsPrint, 1);

    // Evaluate the Node-compat bootstrap (defines console, require, http, events, …).
    const bsz = try arena.dupeZ(u8, bootstrap_src);
    const bval = c.JS_Eval(ctx, bsz.ptr, bsz.len, "<bootstrap>", c.JS_EVAL_TYPE_GLOBAL);
    if (c.qjs_is_exception(bval) != 0) {
        reportIfException(bval);
        return error.BootstrapFailed;
    }
    c.qjs_free(ctx, bval);

    if (args.len < 2) {
        std.debug.print("usage: qjs-run [run] <app.js>\n", .{});
        return;
    }
    const file = if (args.len >= 3 and std.mem.eql(u8, args[1], "run")) args[2] else args[1];
    const src = std.Io.Dir.cwd().readFileAlloc(g_io, file, arena, .limited(4 * 1024 * 1024)) catch {
        std.debug.print("qjs: cannot read {s}\n", .{file});
        return;
    };
    const srcz = try arena.dupeZ(u8, src);
    const fname = try arena.dupeZ(u8, file);

    // Tell the bootstrap require() where the entry file lives (resolves node_modules from there).
    _ = c.JS_SetPropertyStr(ctx, global, "__entryPath", c.JS_NewStringLen(ctx, fname.ptr, fname.len));

    const val = c.JS_Eval(ctx, srcz.ptr, srcz.len, fname.ptr, c.JS_EVAL_TYPE_GLOBAL);
    if (c.qjs_is_exception(val) != 0) {
        reportIfException(val);
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
