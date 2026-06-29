//! Lumen playground compile service.
//!
//! A long-running HTTP server for the Lumen playground. On `POST /compile` it
//! takes a Lumen source body, runs the compiler targeting WebAssembly, and
//! returns the resulting `.wasm` bytes. The service only COMPILES code — it
//! never runs user programs (the browser runs the wasm), so the only guards are
//! a per-compile timeout and a maximum request body size.
//!
//! Routes:
//!   POST /compile  -> 200 application/wasm with the compiled bytes,
//!                     or 400 application/json {"error": "..."} on a compile error.
//!   GET  /health   -> 200 "ok".
//!   OPTIONS *      -> 204 (CORS preflight).
//!
//! Every response carries permissive CORS headers so a browser playground on any
//! origin can call it.

const std = @import("std");

/// Maximum accepted request body, in bytes. Bodies larger than this are rejected
/// before any compile work happens.
const max_body_size: usize = 512 * 1024;

/// Per-compile wall-clock timeout, in seconds. Enforced via coreutils `timeout`.
const compile_timeout_secs: u32 = 20;

/// Working directory the compiler runs in. The compiler writes `play.wasm` next
/// to its input, so each compile happens inside this directory.
const work_dir = "/tmp/lumen-playground";

/// Source/output/diagnostic file names inside `work_dir`.
const src_name = "play.ts";
const wasm_name = "play.wasm";
const err_name = "err.txt";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var log_buf: [1024]u8 = undefined;
    var log_fw: std.Io.File.Writer = .init(.stderr(), io, &log_buf);
    const log = &log_fw.interface;

    // Ensure the compile working directory exists.
    std.Io.Dir.cwd().createDirPath(io, work_dir) catch {};

    const port = readPort(init.environ_map);
    var addr = std.Io.net.IpAddress.parse("0.0.0.0", port) catch unreachable;

    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        try log.print("error: could not listen on 0.0.0.0:{d}: {s}\n", .{ port, @errorName(e) });
        try log.flush();
        std.process.exit(1);
    };
    defer server.deinit(io);

    try log.print("lumen playground compile service listening on 0.0.0.0:{d}\n", .{port});
    try log.flush();

    while (true) {
        const stream = server.accept(io) catch |e| {
            try log.print("accept error: {s}\n", .{@errorName(e)});
            try log.flush();
            continue;
        };
        // Each connection gets its own scratch arena so one request's
        // allocations are reclaimed before the next is served.
        var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer conn_arena.deinit();
        handleConnection(conn_arena.allocator(), io, stream) catch |e| {
            try log.print("connection error: {s}\n", .{@errorName(e)});
            try log.flush();
        };
        stream.close(io);
    }
}

/// Reads the listen port from `PORT` (default 8080).
fn readPort(environ_map: *std.process.Environ.Map) u16 {
    const val = environ_map.get("PORT") orelse return 8080;
    return std.fmt.parseInt(u16, std.mem.trim(u8, val, " \t\r\n"), 10) catch 8080;
}

const Request = struct {
    method: []const u8,
    path: []const u8,
    content_length: usize,
};

/// Reads and parses the request head (request line + headers) from `r`. Returns
/// null if the stream closed before a complete head arrived.
fn readRequestHead(arena: std.mem.Allocator, r: *std.Io.Reader) !?Request {
    // Request line, e.g. "POST /compile HTTP/1.1".
    const first = r.takeDelimiterInclusive('\n') catch return null;
    const line = std.mem.trimEnd(u8, first, "\r\n");
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const path = it.next() orelse return null;

    var content_length: usize = 0;
    // Header lines until a blank line terminates the head.
    while (true) {
        const raw = r.takeDelimiterInclusive('\n') catch break;
        const h = std.mem.trimEnd(u8, raw, "\r\n");
        if (h.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        const name = std.mem.trim(u8, h[0..colon], " \t");
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }

    return .{
        .method = try arena.dupe(u8, method),
        .path = try arena.dupe(u8, path),
        .content_length = content_length,
    };
}

fn handleConnection(arena: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) !void {
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    var write_buf: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    const req = (try readRequestHead(arena, r)) orelse return;

    // CORS preflight: answer every OPTIONS with 204 and the permissive headers.
    if (std.mem.eql(u8, req.method, "OPTIONS")) {
        try writeStatusOnly(w, "204 No Content");
        return;
    }

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/health")) {
        try writeText(w, "200 OK", "text/plain", "ok");
        return;
    }

    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/compile")) {
        try handleCompile(arena, io, r, w, req.content_length);
        return;
    }

    try writeJsonError(w, "404 Not Found", "not found");
}

fn handleCompile(
    arena: std.mem.Allocator,
    io: std.Io,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    content_length: usize,
) !void {
    if (content_length == 0) {
        try writeJsonError(w, "400 Bad Request", "empty request body");
        return;
    }
    if (content_length > max_body_size) {
        try writeJsonError(w, "413 Payload Too Large", "source too large");
        return;
    }

    const body = try arena.alloc(u8, content_length);
    r.readSliceAll(body) catch {
        try writeJsonError(w, "400 Bad Request", "incomplete request body");
        return;
    };

    var dir = std.Io.Dir.cwd().openDir(io, work_dir, .{}) catch {
        try writeJsonError(w, "500 Internal Server Error", "service working directory unavailable");
        return;
    };
    defer dir.close(io);

    // Fresh inputs/outputs for this compile.
    dir.deleteFile(io, wasm_name) catch {};
    dir.deleteFile(io, err_name) catch {};
    dir.writeFile(io, .{ .sub_path = src_name, .data = body }) catch {
        try writeJsonError(w, "500 Internal Server Error", "could not stage source");
        return;
    };

    // Run the compiler in the working directory.
    // Wrap the compile in `timeout` when available (it is on the deployed
    // Linux image, via coreutils) so a pathological input cannot hang a worker;
    // fall back to a plain invocation on hosts without it (e.g. local macOS).
    // The shell redirects the diagnostic stream to a file we read back on
    // failure. `lumen compile --wasm play.ts` writes `play.wasm` next to it.
    const cmd = std.fmt.allocPrint(
        arena,
        "if command -v timeout >/dev/null 2>&1; then timeout {d} lumen compile --wasm {s} 2>{s}; " ++
            "else lumen compile --wasm {s} 2>{s}; fi",
        .{ compile_timeout_secs, src_name, err_name, src_name, err_name },
    ) catch unreachable;

    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", cmd },
        .cwd = .{ .path = work_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        try writeJsonError(w, "500 Internal Server Error", "could not start the compiler");
        return;
    };

    const term = child.wait(io) catch {
        try writeJsonError(w, "500 Internal Server Error", "compile was interrupted");
        return;
    };

    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (ok) {
        const wasm = dir.readFileAlloc(io, wasm_name, arena, .limited(64 * 1024 * 1024)) catch {
            try writeJsonError(w, "500 Internal Server Error", "compiler produced no output");
            return;
        };
        try writeBytes(w, "200 OK", "application/wasm", wasm);
        return;
    }

    // Compile error (or timeout): return the captured diagnostic text.
    const exit_code: ?u8 = switch (term) {
        .exited => |code| code,
        else => null,
    };
    const diag_raw = dir.readFileAlloc(io, err_name, arena, .limited(256 * 1024)) catch "";
    const diag = std.mem.trim(u8, diag_raw, " \t\r\n");
    const message = if (exit_code != null and exit_code.? == 124)
        "compile timed out"
    else if (diag.len > 0)
        diag
    else
        "compilation failed";
    try writeJsonError(w, "400 Bad Request", message);
}

/// Permissive CORS headers sent on every response.
const cors_headers =
    "Access-Control-Allow-Origin: *\r\n" ++
    "Access-Control-Allow-Methods: POST, OPTIONS\r\n" ++
    "Access-Control-Allow-Headers: Content-Type\r\n";

fn writeStatusOnly(w: *std.Io.Writer, status: []const u8) !void {
    try w.print(
        "HTTP/1.1 {s}\r\n" ++
            cors_headers ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n\r\n",
        .{status},
    );
    try w.flush();
}

fn writeText(w: *std.Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try writeBytes(w, status, content_type, body);
}

fn writeBytes(w: *std.Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try w.print(
        "HTTP/1.1 {s}\r\n" ++
            cors_headers ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try w.writeAll(body);
    try w.flush();
}

/// Writes a JSON error response: `{"error": "<message>"}` with the message
/// safely escaped for embedding in a JSON string.
fn writeJsonError(w: *std.Io.Writer, status: []const u8, message: []const u8) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var fixed = std.heap.FixedBufferAllocator.init(&jsonScratch);
    const a = fixed.allocator();
    buf.appendSlice(a, "{\"error\":\"") catch {};
    appendJsonEscaped(a, &buf, message);
    buf.appendSlice(a, "\"}") catch {};
    try writeBytes(w, status, "application/json", buf.items);
}

/// Scratch buffer for building JSON error bodies without touching an arena;
/// diagnostics are bounded (the file read is capped) and JSON escaping at most
/// doubles their size.
var jsonScratch: [768 * 1024]u8 = undefined;

fn appendJsonEscaped(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(a, "\\\"") catch return,
            '\\' => buf.appendSlice(a, "\\\\") catch return,
            '\n' => buf.appendSlice(a, "\\n") catch return,
            '\r' => buf.appendSlice(a, "\\r") catch return,
            '\t' => buf.appendSlice(a, "\\t") catch return,
            0...8, 11, 12, 14...31 => {
                var tmp: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return;
                buf.appendSlice(a, hex) catch return;
            },
            else => buf.append(a, c) catch return,
        }
    }
}
