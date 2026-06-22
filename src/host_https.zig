//! HOST runtime (Node axis — NOT ECMA-262): `https` via Zig std's `std.http.Client`, which bundles
//! TLS 1.3 + HTTP + cert verification + redirects. First cut is a BLOCKING one-shot request (it stalls
//! the event loop for the round-trip) — enough to make `fetch('https://…')` and `https.get` work for
//! axios/got/node-fetch-style usage; an async (libxev) TLS path is a follow-up. CLI/host-only.
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;

pub const HttpsResult = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "",
};

/// One-shot blocking HTTPS request via `std.http.Client`. Returns the status + body (arena-owned), or
/// an error string. `method` is an uppercase HTTP method; `headers` are `name`/`value` pairs.
pub fn fetchBlocking(
    self: *Interpreter,
    method: []const u8,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ?HttpsResult {
    const arena = self.arena;
    var client: std.http.Client = .{ .allocator = arena, .io = self.io };
    defer client.deinit();
    // Load the system trust store so the TLS handshake can verify the server certificate.
    // Without the system trust store the TLS handshake can't verify the server cert → fail the request.
    client.ca_bundle.rescan(arena, self.io, std.Io.Clock.now(.real, self.io)) catch return null;

    var body: std.Io.Writer.Allocating = .init(arena);
    const m: std.http.Method = methodOf(method);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = m,
        .payload = payload,
        .response_writer = &body.writer,
        .extra_headers = extra_headers,
    }) catch return null;
    return .{ .status = @intFromEnum(res.status), .body = body.written() };
}

fn methodOf(m: []const u8) std.http.Method {
    const eq = std.mem.eql;
    if (eq(u8, m, "GET")) return .GET;
    if (eq(u8, m, "POST")) return .POST;
    if (eq(u8, m, "PUT")) return .PUT;
    if (eq(u8, m, "DELETE")) return .DELETE;
    if (eq(u8, m, "HEAD")) return .HEAD;
    if (eq(u8, m, "PATCH")) return .PATCH;
    if (eq(u8, m, "OPTIONS")) return .OPTIONS;
    return .GET;
}
