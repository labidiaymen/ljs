//! HOST runtime (Node axis — NOT ECMA-262): `https` via Zig std's `std.http.Client`, which bundles
//! TLS 1.3 + HTTP + cert verification + redirects. First cut is a BLOCKING one-shot request (it stalls
//! the event loop for the round-trip) — enough to make `fetch('https://…')` and `https.get` work for
//! axios/got/node-fetch-style usage; an async (libxev) TLS path is a follow-up. CLI/host-only.
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const Value = @import("value.zig").Value;
const Object = @import("object.zig").Object;
const Completion = @import("completion.zig").Completion;
const host_require = @import("host_require.zig");
const emitEvent = @import("host_process.zig").emitEvent;

pub const Header = struct { name: []const u8, value: []const u8 };
pub const HttpsResult = struct {
    status: u16,
    reason: []const u8 = "",
    body: []const u8,
    headers: []const Header = &.{},
};

/// One-shot blocking HTTPS request via `std.http.Client` (bundles TLS + redirects). Uses the lower-level
/// `request`/`receiveHead` path (not `fetch`) so the response status line, reason, and HEADERS are
/// captured — node-fetch/axios read `content-type`/`content-length`/etc. All slices are arena-owned.
pub fn fetchBlocking(
    self: *Interpreter,
    method_str: []const u8,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ?HttpsResult {
    const arena = self.arena;
    var client: std.http.Client = .{ .allocator = arena, .io = self.io };
    defer client.deinit();
    // Without the system trust store the TLS handshake can't verify the server cert → fail the request.
    client.ca_bundle.rescan(arena, self.io, std.Io.Clock.now(.real, self.io)) catch return null;

    const uri = std.Uri.parse(url) catch return null;
    // Force `Accept-Encoding: identity` so the body streams without a decompressor (keeps this simple
    // and avoids a struct out-param). Transparent gzip is a follow-up if a server ignores this.
    var req = client.request(methodOf(method_str), uri, .{
        .extra_headers = extra_headers,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch return null;
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var bw = req.sendBodyUnflushed(&.{}) catch return null;
        bw.writer.writeAll(p) catch return null;
        bw.end() catch return null;
        (req.connection orelse return null).flush() catch return null;
    } else {
        req.sendBodiless() catch return null;
    }

    const redirect_buffer = arena.alloc(u8, 8 * 1024) catch return null;
    var response = req.receiveHead(redirect_buffer) catch return null;

    // Capture response headers (arena-dupe — the head buffer is reused once we read the body).
    var hdrs: std.ArrayList(Header) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        const n = arena.dupe(u8, h.name) catch return null;
        const v = arena.dupe(u8, h.value) catch return null;
        hdrs.append(arena, .{ .name = n, .value = v }) catch return null;
    }
    const reason = arena.dupe(u8, response.head.reason) catch return null;

    // Read the body (identity-encoded — see the Accept-Encoding override above).
    var out: std.Io.Writer.Allocating = .init(arena);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch return null;

    return .{ .status = @intFromEnum(response.head.status), .reason = reason, .body = out.written(), .headers = hdrs.items };
}

// ════════════════════════════════════════════════════════════════════════════
//  the `https` module: require('https') → https.get / https.request (+ Agent stubs)
// ════════════════════════════════════════════════════════════════════════════

fn fn_(self: *Interpreter, name: []const u8) EvalError!*Object {
    const f = try Object.createNative(self.arena, .https_method, name);
    f.prototype = self.functionProto();
    try f.defineData("name", .{ .string = name }, false, false, true);
    return f;
}

pub fn build(self: *Interpreter) EvalError!*Object {
    const mod = try Object.create(self.arena, self.objectProto());
    for ([_][]const u8{ "request", "get", "Agent", "globalAgent", "Server", "createServer" }) |n|
        try mod.defineData(n, .{ .object = try fn_(self, n) }, true, false, true);
    // A globalAgent OBJECT (some libs read https.globalAgent.options / .maxSockets).
    const ga = try Object.create(self.arena, self.objectProto());
    try ga.defineData("maxSockets", .{ .number = std.math.inf(f64) }, true, true, true);
    try ga.defineData("options", .{ .object = try Object.create(self.arena, self.objectProto()) }, true, true, true);
    try mod.defineData("globalAgent", .{ .object = ga }, true, false, true);
    return mod;
}

/// Minimal `tls` module — enough for axios/ws/node-fetch to LOAD (they `require('tls')` for the secure
/// socket layer). The actual TLS goes through std.http.Client (https). Real `tls.connect` is a follow-up.
pub fn buildTls(self: *Interpreter) EvalError!*Object {
    const mod = try Object.create(self.arena, self.objectProto());
    for ([_][]const u8{ "connect", "createServer", "createSecureContext", "TLSSocket", "Server", "checkServerIdentity", "createSecurePair" }) |n|
        try mod.defineData(n, .{ .object = try fn_(self, n) }, true, false, true);
    // tls.rootCertificates — some libs read it; an empty array is fine.
    try mod.defineData("rootCertificates", .{ .object = try Object.createArray(self.arena, self.arrayProto()) }, true, false, true);
    try mod.defineData("DEFAULT_MIN_VERSION", .{ .string = "TLSv1.2" }, true, false, true);
    try mod.defineData("DEFAULT_MAX_VERSION", .{ .string = "TLSv1.3" }, true, false, true);
    return mod;
}

/// A stub module: each name is an `.https_method` native (returns an empty object / passthrough — see
/// `method`). Enough for packages that `require` these at load but use them lazily.
fn buildStub(self: *Interpreter, names: []const []const u8) EvalError!*Object {
    const mod = try Object.create(self.arena, self.objectProto());
    for (names) |n| try mod.defineData(n, .{ .object = try fn_(self, n) }, true, false, true);
    return mod;
}
pub fn buildPunycode(self: *Interpreter) EvalError!*Object {
    const mod = try buildStub(self, &.{ "toASCII", "toUnicode", "encode", "decode" });
    const ucs2 = try buildStub(self, &.{ "encode", "decode" });
    try mod.defineData("ucs2", .{ .object = ucs2 }, true, false, true);
    try mod.defineData("version", .{ .string = "2.3.1" }, true, false, true);
    return mod;
}
pub fn buildV8(self: *Interpreter) EvalError!*Object {
    return buildStub(self, &.{ "serialize", "deserialize", "getHeapStatistics", "getHeapSpaceStatistics", "setFlagsFromString", "takeCoverage", "stopCoverage" });
}
pub fn buildHttp2(self: *Interpreter) EvalError!*Object {
    const mod = try buildStub(self, &.{ "connect", "createServer", "createSecureServer", "getDefaultSettings", "getPackedSettings", "getUnpackedSettings", "Http2Session", "Http2Stream", "ServerHttp2Stream" });
    try mod.defineData("constants", .{ .object = try Object.create(self.arena, self.objectProto()) }, true, false, true);
    return mod;
}
pub fn buildDiagnosticsChannel(self: *Interpreter) EvalError!*Object {
    return buildStub(self, &.{ "channel", "hasSubscribers", "subscribe", "unsubscribe", "tracingChannel" });
}
pub fn buildWorkerThreads(self: *Interpreter) EvalError!*Object {
    const mod = try buildStub(self, &.{ "Worker", "MessageChannel", "MessagePort", "moveMessagePortToContext", "receiveMessageOnPort", "markAsUntransferable", "getEnvironmentData", "setEnvironmentData", "BroadcastChannel" });
    try mod.defineData("isMainThread", .{ .boolean = true }, true, false, true);
    try mod.defineData("threadId", .{ .number = 0 }, true, false, true);
    try mod.defineData("parentPort", .null, true, false, true);
    try mod.defineData("workerData", .null, true, false, true);
    return mod;
}

/// A fresh `events.EventEmitter` instance (so `.on`/`.once`/`.emit` resolve through its prototype).
fn newEmitter(self: *Interpreter) EvalError!*Object {
    const ec = try host_require.loadCoreModulePub(self, "events");
    if (ec.normal == .object) {
        if (ec.normal.object.get("EventEmitter")) |ee| if (ee == .object) {
            const c = try self.construct(ee.object, &.{});
            if (c.normal == .object) return c.normal.object;
        };
    }
    return Object.create(self.arena, self.objectProto());
}

pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;
    if (eq(u8, name, "request") or eq(u8, name, "get")) return httpsRequest(self, name, args);
    if (eq(u8, name, "end")) return httpsEnd(self, this_val);
    if (eq(u8, name, "write") or eq(u8, name, "setHeader") or eq(u8, name, "abort") or eq(u8, name, "destroy") or eq(u8, name, "setTimeout")) {
        // `write` buffers the body; the rest are no-op stubs that return `this` for chaining.
        if (eq(u8, name, "write") and this_val == .object and args.len > 0 and args[0] == .string) {
            const prev: []const u8 = if (this_val.object.get("%body%")) |b| (if (b == .string) b.string else "") else "";
            const combined = std.mem.concat(self.arena, u8, &.{ prev, args[0].string }) catch return error.OutOfMemory;
            try this_val.object.defineData("%body%", .{ .string = combined }, false, false, true);
        }
        return .{ .normal = this_val };
    }
    if (eq(u8, name, "checkServerIdentity")) return .{ .normal = .undefined }; // undefined = identity OK
    // punycode: ASCII-domain passthrough (good enough for non-IDN hostnames, the common case).
    if (eq(u8, name, "toASCII") or eq(u8, name, "toUnicode") or eq(u8, name, "encode") or eq(u8, name, "decode"))
        return .{ .normal = if (args.len > 0) args[0] else .{ .string = "" } };
    // diagnostics_channel.channel(name) → an inert channel; hasSubscribers → false.
    if (eq(u8, name, "hasSubscribers")) return .{ .normal = .{ .boolean = false } };
    if (eq(u8, name, "channel")) {
        const ch = try Object.create(self.arena, self.objectProto());
        try ch.defineData("hasSubscribers", .{ .boolean = false }, true, true, true);
        for ([_][]const u8{ "publish", "subscribe", "unsubscribe" }) |m|
            try ch.defineData(m, .{ .object = try fn_(self, m) }, true, false, true);
        return .{ .normal = .{ .object = ch } };
    }
    // Everything else (Agent/Server/createServer + the tls stubs connect/createSecureContext/TLSSocket/…)
    // → a fresh empty object: enough to LOAD. A real https/tls server + tls.connect is a later cycle.
    return .{ .normal = .{ .object = try Object.create(self.arena, self.objectProto()) } };
}

/// https.request(url|options[, options][, callback]) / https.get(...) — build a ClientRequest emitter;
/// `https.get` also auto-calls `.end()`. The trailing function arg is a `'response'` listener.
fn httpsRequest(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const req = try newEmitter(self);
    var url: []const u8 = "";
    var cb: Value = .undefined;
    for (args) |a| {
        switch (a) {
            .string => url = a.string,
            .object => |o| {
                if (o.kind == .function) {
                    cb = a;
                } else {
                    // an options object: assemble the URL from protocol/host/port/path.
                    const host = strOf(o, "hostname") orelse strOf(o, "host") orelse "";
                    const path = strOf(o, "path") orelse "/";
                    url = std.fmt.allocPrint(self.arena, "https://{s}{s}", .{ host, path }) catch return error.OutOfMemory;
                    if (o.get("method")) |m| if (m == .string) try req.defineData("%method%", m, false, false, true);
                }
            },
            else => {},
        }
    }
    try req.defineData("%url%", .{ .string = url }, false, false, true);
    // `end`/`write` methods on the request instance.
    try req.defineData("end", .{ .object = try fn_(self, "end") }, true, false, true);
    try req.defineData("write", .{ .object = try fn_(self, "write") }, true, false, true);
    for ([_][]const u8{ "setHeader", "abort", "destroy", "setTimeout" }) |m|
        try req.defineData(m, .{ .object = try fn_(self, m) }, true, false, true);
    if (cb != .undefined) {
        // add the callback as a 'response' listener via the emitter's `on`.
        if (req.get("on")) |onf| {
            if (onf == .object) {
                _ = try self.callFunction(onf.object, &.{ .{ .string = "response" }, cb }, .{ .object = req });
            }
        }
    }
    if (eq2(name, "get")) return httpsEnd(self, .{ .object = req });
    return .{ .normal = .{ .object = req } };
}

fn eq2(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn strOf(o: *Object, key: []const u8) ?[]const u8 {
    if (o.get(key)) |v| if (v == .string) return v.string;
    return null;
}

/// `.end()` — perform the blocking TLS request, then emit 'response' (an IncomingMessage) and stream
/// the body as 'data' + 'end' on the response.
fn httpsEnd(self: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object) return .{ .normal = .undefined };
    const req = this_val.object;
    const url: []const u8 = if (req.get("%url%")) |u| (if (u == .string) u.string else "") else "";
    const method_s: []const u8 = if (req.get("%method%")) |m| (if (m == .string) m.string else "GET") else "GET";
    const body: ?[]const u8 = if (req.get("%body%")) |b| (if (b == .string) b.string else null) else null;
    const r = fetchBlocking(self, method_s, url, &.{}, body) orelse {
        _ = try emitEvent(self, .{ .object = req }, "error", &.{(try self.throwError("Error", "https request failed (TLS)")).throw});
        return .{ .normal = .undefined };
    };
    const res = try newEmitter(self);
    try res.defineData("statusCode", .{ .number = @floatFromInt(r.status) }, true, true, true);
    try res.defineData("statusMessage", .{ .string = r.reason }, true, true, true);
    // res.headers — Node lower-cases header names and joins duplicates; this is the common-case shape.
    const headers_obj = try Object.create(self.arena, self.objectProto());
    for (r.headers) |h| {
        const lower = try std.ascii.allocLowerString(self.arena, h.name);
        try headers_obj.defineData(lower, .{ .string = h.value }, true, true, true);
    }
    try res.defineData("headers", .{ .object = headers_obj }, true, true, true);
    try res.defineData("setEncoding", .{ .object = try fn_(self, "setEncoding") }, true, false, true);
    // emit 'response' (the handler registers res.on('data')/on('end')), then deliver the body.
    _ = try emitEvent(self, .{ .object = req }, "response", &.{.{ .object = res }});
    if (r.body.len != 0) _ = try emitEvent(self, .{ .object = res }, "data", &.{.{ .string = r.body }});
    _ = try emitEvent(self, .{ .object = res }, "end", &.{});
    return .{ .normal = .{ .object = req } };
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
