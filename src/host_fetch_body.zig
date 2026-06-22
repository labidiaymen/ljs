//! HOST runtime (Node axis — NOT ECMA-262): the WHATWG `Response` / `Request` globals (the Body
//! mixin). These are the data objects `fetch()` returns / takes; this module implements them
//! standalone — the integrator wires `fetch()` itself. Installed host-only as GLOBALS (via
//! `host_setup`); NEVER on the Test262 engine surface, so 0 Test262 regressions by construction.
//!
//! Mechanics (mirrors `host_url.zig`):
//!   • Each constructor/method is a `.fetch_body_method` native whose `native_name` selects the
//!     operation; a hidden own `"%kind%"` on the function distinguishes the family (Response ctor,
//!     Request ctor, the proto-method/getter families, and the Response statics).
//!   • A constructor invoked via `new` receives the freshly-created instance as `this_val` (see
//!     `interp_expr.constructNT`, which lists `.fetch_body_method` as constructible). The constructor
//!     stores the raw body bytes + a "used" flag + the other props as own data properties on the
//!     instance.
//!   • Body bytes live in a hidden own `"%body%"` (a string of raw bytes, or absent when null) and a
//!     mutable `"%used%"` boolean. `.text()`/`.json()`/`.arrayBuffer()` return REAL Promises built
//!     via `interp_async.newPromise` + `fulfillPromise`/`rejectPromise`.
//!   • `.headers` is a real `Headers` instance built via the global `Headers` constructor (looked up
//!     off the realm) so it works once integrated; if `Headers` is absent it degrades to a plain
//!     object (a documented first-cut fallback).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const async_mod = @import("interp_async.zig");
const host_require = @import("host_require.zig");

// ════════════════════════════════════════════════════════════════════════════
//  install (globals)
// ════════════════════════════════════════════════════════════════════════════

/// Build + declare the `Response` and `Request` globals on `self.globals`, mirrored onto the reified
/// global object. Called from `host_setup.installHostGlobals`.
pub fn install(self: *Interpreter) EvalError!void {
    const env = self.globals orelse return;
    const ctors = [_]struct { name: []const u8, ctor: *Object }{
        .{ .name = "Response", .ctor = try makeResponseCtor(self) },
        .{ .name = "Request", .ctor = try makeRequestCtor(self) },
    };
    for (ctors) |p| {
        try env.declare(p.name, .{ .object = p.ctor }, true, true);
        if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
            try gb.value.object.defineData(p.name, .{ .object = p.ctor }, true, false, true);
    }
    // The global `fetch(input[, init]) -> Promise<Response>` (drives the http client → builds a Response).
    const fetch_fn = try makeMethod(self, "fetch_fn", "fetch");
    try env.declare("fetch", .{ .object = fetch_fn }, true, true);
    if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
        try gb.value.object.defineData("fetch", .{ .object = fetch_fn }, true, false, true);
}

// ── constructor / prototype builders ─────────────────────────────────────────

/// Make a `.fetch_body_method` native function flagged with `kind` (read off `"%kind%"` in dispatch)
/// and selecting `name` (the operation, via `native_name`). Proto-linked to %Function.prototype%, no
/// own `prototype` (a method).
fn makeMethod(self: *Interpreter, kind: []const u8, name: []const u8) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .fetch_body_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try fn_obj.defineData("%kind%", .{ .string = kind }, false, false, true);
    return fn_obj;
}

/// Make a constructor function (`ctor_kind` selects the family) with a `prototype` object whose
/// `methods` are `.fetch_body_method` natives and `getters` are get-only accessor pairs (flagged
/// `proto_kind`).
fn makeCtor(self: *Interpreter, ctor_kind: []const u8, proto_kind: []const u8, ctor_name: []const u8, methods: []const []const u8, getters: []const []const u8) EvalError!*Object {
    const arena = self.arena;
    const proto = try Object.create(arena, self.objectProto());

    const ctor = try Object.createNative(arena, .fetch_body_method, ctor_name);
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = ctor_name }, false, false, true);
    try ctor.defineData("%kind%", .{ .string = ctor_kind }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    for (methods) |m| {
        const fn_obj = try makeMethod(self, proto_kind, m);
        try proto.defineData(m, .{ .object = fn_obj }, true, false, true);
    }
    for (getters) |g| {
        const getter = try makeMethod(self, proto_kind, g);
        try proto.defineAccessorEx(g, getter, null, false);
    }
    return ctor;
}

const body_methods = [_][]const u8{ "text", "json", "arrayBuffer", "clone" };
const response_getters = [_][]const u8{ "status", "statusText", "ok", "headers", "bodyUsed", "type", "url", "redirected" };
const request_getters = [_][]const u8{ "url", "method", "headers", "bodyUsed" };

fn makeResponseCtor(self: *Interpreter) EvalError!*Object {
    const ctor = try makeCtor(self, "response_ctor", "response", "Response", &body_methods, &response_getters);
    // Statics: Response.json / Response.error / Response.redirect.
    for ([_][]const u8{ "json", "error", "redirect" }) |s| {
        const fn_obj = try makeMethod(self, "response_static", s);
        try ctor.defineData(s, .{ .object = fn_obj }, true, false, true);
    }
    return ctor;
}

fn makeRequestCtor(self: *Interpreter) EvalError!*Object {
    return makeCtor(self, "request_ctor", "request", "Request", &body_methods, &request_getters);
}

// ════════════════════════════════════════════════════════════════════════════
//  dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a `.fetch_body_method` native. `func` carries the family in `"%kind%"`; `this_val` is the
/// receiver (the new instance for a constructor, the Response/Request instance for a method).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const kind = if (func.get("%kind%")) |v| (if (v == .string) v.string else "") else "";
    const name = func.native_name;
    const eq = std.mem.eql;
    if (eq(u8, kind, "response_ctor")) return responseConstruct(self, this_val, args);
    if (eq(u8, kind, "request_ctor")) return requestConstruct(self, this_val, args);
    if (eq(u8, kind, "response_static")) return responseStatic(self, name, args);
    if (eq(u8, kind, "response")) return bodyMethod(self, name, this_val, true);
    if (eq(u8, kind, "request")) return bodyMethod(self, name, this_val, false);
    if (eq(u8, kind, "fetch_fn")) return fetchImpl(self, args);
    if (eq(u8, kind, "fetch_cb")) return fetchCallback(self, name, func, args);
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  fetch() — drive the http client, resolve a Promise<Response>
// ════════════════════════════════════════════════════════════════════════════

/// A `.fetch_body_method` callback (kind "fetch_cb") carrying the shared fetch context on `"%ctx%"`.
fn makeFetchCb(self: *Interpreter, role: []const u8, ctx: *Object) EvalError!*Object {
    const cb = try makeMethod(self, "fetch_cb", role);
    try cb.defineData("%ctx%", .{ .object = ctx }, false, false, true);
    return cb;
}

fn callMethodNamed(self: *Interpreter, obj: *Object, name: []const u8, call_args: []const Value) EvalError!void {
    const m = obj.get(name) orelse return;
    if (m != .object or m.object.kind != .function) return;
    _ = try self.callFunction(m.object, call_args, .{ .object = obj });
}

/// `fetch(input[, init])` → Promise<Response>. Issues an `http.request`, accumulates the response body,
/// and fulfills with a `Response` (or rejects on a transport error).
fn fetchImpl(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const promise = try async_mod.newPromise(self);
    const input: Value = if (args.len > 0) args[0] else .undefined;
    const init: Value = if (args.len > 1) args[1] else .undefined;

    // URL: a string, or a Request's `.url`.
    var url_val: Value = input;
    if (input == .object) {
        if (input.object.get("url")) |u| url_val = u;
    }
    // options { method, headers } + an optional body, lifted off init (and a Request's own fields).
    const opts = try Object.create(arena, self.objectProto());
    var body_val: Value = .undefined;
    if (input == .object) {
        if (input.object.get("method")) |m| try opts.defineData("method", m, true, true, true);
        if (input.object.get("headers")) |h| try opts.defineData("headers", h, true, true, true);
    }
    if (init == .object) {
        if (init.object.get("method")) |m| try opts.defineData("method", m, true, true, true);
        if (init.object.get("headers")) |h| try opts.defineData("headers", h, true, true, true);
        if (init.object.get("body")) |b| body_val = b;
    }

    // HTTPS → the blocking std.http.Client TLS path (the async http client is plaintext-only). Builds a
    // Response directly from the one-shot result. (v1: no custom request headers / streaming.)
    if (url_val == .string and std.mem.startsWith(u8, url_val.string, "https://")) {
        const method_s: []const u8 = if (opts.get("method")) |m| (if (m == .string) m.string else "GET") else "GET";
        const body_bytes: ?[]const u8 = if (body_val == .string) body_val.string else null;
        if (@import("host_https.zig").fetchBlocking(self, method_s, url_val.string, &.{}, body_bytes)) |r| {
            const ri = try Object.create(arena, self.objectProto());
            try ri.defineData("status", .{ .number = @floatFromInt(r.status) }, true, true, true);
            const resp = try makeResponseInstance(self, &.{ .{ .string = r.body }, .{ .object = ri } });
            if (resp.isAbrupt()) try async_mod.rejectPromise(self, promise, resp.throw) else try async_mod.fulfillPromise(self, promise, resp.normal);
        } else {
            try async_mod.rejectPromise(self, promise, (try self.throwError("TypeError", "https request failed (TLS)")).throw);
        }
        return .{ .normal = .{ .object = promise } };
    }

    // shared context: the promise + accumulated chunks (a JS Array).
    const ctx = try Object.create(arena, self.objectProto());
    try ctx.defineData("%promise%", .{ .object = promise }, false, false, true);

    const httpc = try host_require.loadCoreModulePub(self, "http");
    if (httpc.isAbrupt()) return httpc;
    const http = httpc.normal;
    const request = if (http == .object) http.object.get("request") else null;
    if (request == null or request.? != .object) {
        try async_mod.rejectPromise(self, promise, (try self.throwError("TypeError", "fetch: http.request unavailable")).throw);
        return .{ .normal = .{ .object = promise } };
    }
    const resp_cb = try makeFetchCb(self, "resp", ctx);
    const rc = try self.callFunction(request.?.object, &.{ url_val, .{ .object = opts }, .{ .object = resp_cb } }, http);
    if (rc.isAbrupt()) {
        try async_mod.rejectPromise(self, promise, rc.throw);
        return .{ .normal = .{ .object = promise } };
    }
    if (rc.normal == .object) {
        const req = rc.normal.object;
        try callMethodNamed(self, req, "on", &.{ .{ .string = "error" }, .{ .object = try makeFetchCb(self, "err", ctx) } });
        if (body_val != .undefined and body_val != .null) try callMethodNamed(self, req, "write", &.{body_val});
        try callMethodNamed(self, req, "end", &.{});
    }
    return .{ .normal = .{ .object = promise } };
}

fn fetchCtxOf(func: *Object) ?*Object {
    const c = func.get("%ctx%") orelse return null;
    return if (c == .object) c.object else null;
}

fn fetchCallback(self: *Interpreter, role: []const u8, func: *Object, args: []const Value) EvalError!Completion {
    const ctx = fetchCtxOf(func) orelse return .{ .normal = .undefined };
    const promise = if (ctx.get("%promise%")) |p| (if (p == .object) p.object else return .{ .normal = .undefined }) else return .{ .normal = .undefined };
    const eq = std.mem.eql;
    if (eq(u8, role, "resp")) {
        const res = if (args.len > 0 and args[0] == .object) args[0].object else return .{ .normal = .undefined };
        try ctx.defineData("%res%", .{ .object = res }, false, false, true);
        try callMethodNamed(self, res, "on", &.{ .{ .string = "data" }, .{ .object = try makeFetchCb(self, "data", ctx) } });
        try callMethodNamed(self, res, "on", &.{ .{ .string = "end" }, .{ .object = try makeFetchCb(self, "end", ctx) } });
    } else if (eq(u8, role, "data")) {
        // Append the chunk's bytes onto the running `%body%` string (a Buffer or a decoded string).
        if (args.len > 0) {
            const prev: []const u8 = if (ctx.get("%body%")) |b| (if (b == .string) b.string else "") else "";
            const add: []const u8 = bytesOfView(args[0]) orelse (if (args[0] == .string) args[0].string else "");
            if (add.len != 0) {
                const combined = std.mem.concat(self.arena, u8, &.{ prev, add }) catch return error.OutOfMemory;
                try ctx.defineData("%body%", .{ .string = combined }, false, false, true);
            }
        }
    } else if (eq(u8, role, "end")) {
        const body_str: []const u8 = if (ctx.get("%body%")) |b| (if (b == .string) b.string else "") else "";
        const res = if (ctx.get("%res%")) |r| (if (r == .object) r.object else null) else null;
        const init = try Object.create(self.arena, self.objectProto());
        if (res) |r| {
            if (r.get("statusCode")) |sc| try init.defineData("status", sc, true, true, true);
            if (r.get("statusMessage")) |sm| try init.defineData("statusText", sm, true, true, true);
            if (r.get("headers")) |hh| try init.defineData("headers", hh, true, true, true);
        }
        const resp = try makeResponseInstance(self, &.{ .{ .string = body_str }, .{ .object = init } });
        if (resp.isAbrupt()) {
            try async_mod.rejectPromise(self, promise, resp.throw);
        } else {
            try async_mod.fulfillPromise(self, promise, resp.normal);
        }
    } else if (eq(u8, role, "err")) {
        try async_mod.rejectPromise(self, promise, if (args.len > 0) args[0] else (try self.throwError("TypeError", "fetch failed")).throw);
    }
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  body byte helpers
// ════════════════════════════════════════════════════════════════════════════

/// The raw bytes viewed by a typed array / Buffer / DataView / ArrayBuffer value, or null.
fn bytesOfView(v: Value) ?[]const u8 {
    if (v != .object) return null;
    const o = v.object;
    if (o.typed_array) |ta| {
        const ab = ta.buffer.array_buffer orelse return null;
        const start = ta.byte_offset;
        const end = start + ta.array_length;
        if (end > ab.bytes.len) return null;
        return ab.bytes[start..end];
    }
    if (o.data_view) |dv| {
        const ab = dv.buffer.array_buffer orelse return null;
        const start = dv.byte_offset;
        const end = start + dv.byte_length;
        if (end > ab.bytes.len) return null;
        return ab.bytes[start..end];
    }
    if (o.array_buffer) |ab| return ab.bytes;
    return null;
}

/// Coerce a body init value to its raw bytes (arena-owned). A string is taken as-is (its WTF-8
/// storage); a Buffer / typed array / ArrayBuffer / DataView yields its viewed bytes; undefined/null
/// yields null (no body). Anything else is ToString'd. Returns the abrupt completion on a throwing
/// ToString.
fn bodyToBytes(self: *Interpreter, v: Value) EvalError!union(enum) { bytes: ?[]const u8, abrupt: Completion } {
    switch (v) {
        .undefined, .null => return .{ .bytes = null },
        .string => |s| return .{ .bytes = s },
        .object => {
            if (bytesOfView(v)) |b| return .{ .bytes = try self.arena.dupe(u8, b) };
            const sc = try self.toStringValuePub(v);
            if (sc.isAbrupt()) return .{ .abrupt = sc };
            return .{ .bytes = sc.normal.string };
        },
        else => {
            const sc = try self.toStringValuePub(v);
            if (sc.isAbrupt()) return .{ .abrupt = sc };
            return .{ .bytes = sc.normal.string };
        },
    }
}

/// Build a real byte-backed ArrayBuffer holding `src`. Used by `.arrayBuffer()`.
fn makeArrayBuffer(self: *Interpreter, src: []const u8) EvalError!*Object {
    const ab = Object.createArrayBuffer(self.arena, self.globalProto("ArrayBuffer"), src.len, null) catch return error.OutOfMemory;
    if (ab.array_buffer) |abd| if (src.len > 0) @memcpy(abd.bytes[0..src.len], src);
    return ab;
}

// ════════════════════════════════════════════════════════════════════════════
//  Headers
// ════════════════════════════════════════════════════════════════════════════

/// Build a `headers` instance from an init value. PREFERS the global `Headers` constructor (so it
/// integrates with the sibling-built `Headers`); degrades to a plain object if `Headers` is absent.
/// Returns the abrupt completion if the `Headers` constructor throws.
fn makeHeaders(self: *Interpreter, init: Value) EvalError!Completion {
    if (self.globals) |g| {
        if (g.lookup("Headers")) |b| {
            if (b.value == .object and interpreter.isCallable(b.value.object)) {
                const args: []const Value = if (init == .undefined) &.{} else &.{init};
                return self.construct(b.value.object, args);
            }
        }
    }
    // Fallback: a plain object copy of the init record (first-cut; degraded — no Headers global yet).
    const obj = try Object.create(self.arena, self.objectProto());
    if (init == .object) {
        var pit = init.object.properties.iterator();
        while (pit.next()) |e| {
            if (!e.value_ptr.enumerable) continue;
            const vc = try self.getProperty(.{ .object = init.object }, e.key_ptr.*);
            if (vc.isAbrupt()) return vc;
            try obj.defineData(e.key_ptr.*, vc.normal, true, true, true);
        }
    }
    return .{ .normal = .{ .object = obj } };
}

// ════════════════════════════════════════════════════════════════════════════
//  Response
// ════════════════════════════════════════════════════════════════════════════

/// Store the common Body-mixin hidden slots: `%body%` (raw bytes string, absent when null) and the
/// mutable `%used%` flag.
fn storeBody(self: *Interpreter, inst: *Object, bytes: ?[]const u8) EvalError!void {
    _ = self;
    if (bytes) |b| try inst.defineData("%body%", .{ .string = b }, false, false, true);
    try inst.defineData("%used%", .{ .boolean = false }, false, true, true);
}

/// `new Response([body][, init])` — body is a string/Buffer/undefined; init = { status, statusText,
/// headers }. Stores status/statusText + the body bytes + a Headers instance on the instance.
fn responseConstruct(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Response constructor requires `new`");
    const inst = this_val.object;

    const body_v: Value = if (args.len > 0) args[0] else .undefined;
    const init: Value = if (args.len > 1) args[1] else .undefined;

    // status (default 200) / statusText (default "") / headers — read off init.
    var status: f64 = 200;
    var status_text: []const u8 = "";
    var headers_init: Value = .undefined;
    if (init == .object) {
        const sc = try self.getProperty(init, "status");
        if (sc.isAbrupt()) return sc;
        if (sc.normal != .undefined) {
            const nc = try self.toNumberV(sc.normal);
            if (nc.isAbrupt()) return nc;
            status = nc.normal.number;
        }
        const stc = try self.getProperty(init, "statusText");
        if (stc.isAbrupt()) return stc;
        if (stc.normal != .undefined) {
            const s = try self.toStringValuePub(stc.normal);
            if (s.isAbrupt()) return s;
            status_text = s.normal.string;
        }
        const hc = try self.getProperty(init, "headers");
        if (hc.isAbrupt()) return hc;
        headers_init = hc.normal;
    }

    const bb = try bodyToBytes(self, body_v);
    const bytes = switch (bb) {
        .bytes => |b| b,
        .abrupt => |c| return c,
    };
    try storeBody(self, inst, bytes);

    const status_i: f64 = @trunc(status);
    try inst.defineData("status", .{ .number = status_i }, true, false, true);
    try inst.defineData("statusText", .{ .string = status_text }, true, false, true);
    try inst.defineData("ok", .{ .boolean = status_i >= 200 and status_i <= 299 }, true, false, true);
    try inst.defineData("type", .{ .string = "default" }, true, false, true);
    try inst.defineData("url", .{ .string = "" }, true, false, true);
    try inst.defineData("redirected", .{ .boolean = false }, true, false, true);

    const hc = try makeHeaders(self, headers_init);
    if (hc.isAbrupt()) return hc;
    try inst.defineData("headers", hc.normal, true, false, true);
    return .{ .normal = .{ .object = inst } };
}

/// Dispatch a `Response.*` static: json / error / redirect.
fn responseStatic(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (eq(u8, name, "json")) {
        // Response.json(data[, init]) — JSON.stringify(data) body, default status 200.
        const data: Value = if (args.len > 0) args[0] else .undefined;
        const json = try @import("builtin_json.zig").stringify(self, &.{data});
        if (json.isAbrupt()) return json;
        const body: Value = if (json.normal == .string) json.normal else .{ .string = "" };
        const init: Value = if (args.len > 1) args[1] else .undefined;
        return makeResponseInstance(self, &.{ body, init });
    }
    if (eq(u8, name, "error")) {
        // Response.error() — a network-error response (status 0, type "error").
        const c = try makeResponseInstance(self, &.{});
        if (c.isAbrupt()) return c;
        const inst = c.normal.object;
        try inst.defineData("status", .{ .number = 0 }, true, false, true);
        try inst.defineData("ok", .{ .boolean = false }, true, false, true);
        try inst.defineData("type", .{ .string = "error" }, true, false, true);
        return c;
    }
    if (eq(u8, name, "redirect")) {
        // Response.redirect(url[, status=302]) — a redirect response.
        const url_v: Value = if (args.len > 0) args[0] else .undefined;
        const uc = try self.toStringValuePub(url_v);
        if (uc.isAbrupt()) return uc;
        var status: f64 = 302;
        if (args.len > 1 and args[1] != .undefined) {
            const nc = try self.toNumberV(args[1]);
            if (nc.isAbrupt()) return nc;
            status = @trunc(nc.normal.number);
        }
        const c = try makeResponseInstance(self, &.{});
        if (c.isAbrupt()) return c;
        const inst = c.normal.object;
        try inst.defineData("status", .{ .number = status }, true, false, true);
        try inst.defineData("url", .{ .string = uc.normal.string }, true, false, true);
        // Mirror the Location header onto the Headers instance if it exposes `set`.
        if (inst.get("headers")) |hv| if (hv == .object) {
            if (hv.object.get("set")) |setf| if (setf == .object and interpreter.isCallable(setf.object)) {
                _ = try self.callFunction(setf.object, &.{ .{ .string = "location" }, uc.normal }, hv);
            };
        };
        return c;
    }
    return .{ .normal = .undefined };
}

/// Construct a fresh Response instance (proto = %Response.prototype%) by running `responseConstruct`.
fn makeResponseInstance(self: *Interpreter, args: []const Value) EvalError!Completion {
    const proto = self.globalProto("Response") orelse self.objectProto();
    const inst = try Object.create(self.arena, proto);
    return responseConstruct(self, .{ .object = inst }, args);
}

// ════════════════════════════════════════════════════════════════════════════
//  Request
// ════════════════════════════════════════════════════════════════════════════

/// `new Request(input[, init])` — input is a URL string or a Request; init = { method, headers,
/// body }. Stores url/method (upper-cased, default GET) + the body bytes + a Headers instance.
fn requestConstruct(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Request constructor requires `new`");
    const inst = this_val.object;

    const input: Value = if (args.len > 0) args[0] else .undefined;
    const init: Value = if (args.len > 1) args[1] else .undefined;

    // url — from a Request input's `url`, else ToString(input).
    var url: []const u8 = "";
    if (input == .object and input.object.get("url") != null) {
        const u = input.object.get("url").?;
        if (u == .string) url = u.string;
    } else {
        const uc = try self.toStringValuePub(input);
        if (uc.isAbrupt()) return uc;
        url = uc.normal.string;
    }

    // method (default GET, upper-cased) / headers / body. A Request input provides defaults; init
    // overrides.
    var method_str: []const u8 = "GET";
    var headers_init: Value = .undefined;
    var body_v: Value = .undefined;
    if (input == .object) {
        if (input.object.get("%body%")) |b| body_v = b;
        if (input.object.get("method")) |m| if (m == .string) {
            method_str = m.string;
        };
        if (input.object.get("headers")) |h| headers_init = h;
    }
    if (init == .object) {
        const mc = try self.getProperty(init, "method");
        if (mc.isAbrupt()) return mc;
        if (mc.normal != .undefined) {
            const s = try self.toStringValuePub(mc.normal);
            if (s.isAbrupt()) return s;
            method_str = s.normal.string;
        }
        const hc = try self.getProperty(init, "headers");
        if (hc.isAbrupt()) return hc;
        if (hc.normal != .undefined) headers_init = hc.normal;
        const bc = try self.getProperty(init, "body");
        if (bc.isAbrupt()) return bc;
        if (bc.normal != .undefined) body_v = bc.normal;
    }

    const method_up = try std.ascii.allocUpperString(self.arena, method_str);
    const bb = try bodyToBytes(self, body_v);
    const bytes = switch (bb) {
        .bytes => |b| b,
        .abrupt => |c| return c,
    };
    try storeBody(self, inst, bytes);

    try inst.defineData("url", .{ .string = url }, true, false, true);
    try inst.defineData("method", .{ .string = method_up }, true, false, true);

    const hc = try makeHeaders(self, headers_init);
    if (hc.isAbrupt()) return hc;
    try inst.defineData("headers", hc.normal, true, false, true);
    return .{ .normal = .{ .object = inst } };
}

// ════════════════════════════════════════════════════════════════════════════
//  Body mixin methods: text / json / arrayBuffer / clone
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a Body-mixin method on a Response/Request instance. `is_response` selects which clone
/// constructor to use.
fn bodyMethod(self: *Interpreter, name: []const u8, this_val: Value, is_response: bool) EvalError!Completion {
    const eq = std.mem.eql;
    if (this_val != .object) return self.throwError("TypeError", "Body method called on non-object");
    const inst = this_val.object;

    // Getters (accessor calls land here with the instance as `this`).
    if (eq(u8, name, "status") or eq(u8, name, "statusText") or eq(u8, name, "ok") or
        eq(u8, name, "headers") or eq(u8, name, "type") or eq(u8, name, "url") or
        eq(u8, name, "redirected") or eq(u8, name, "method"))
        return .{ .normal = inst.get(name) orelse .undefined };
    if (eq(u8, name, "bodyUsed")) {
        const used = inst.get("%used%") orelse Value{ .boolean = false };
        return .{ .normal = used };
    }

    if (eq(u8, name, "clone")) return bodyClone(self, inst, is_response);

    // text / json / arrayBuffer — consume the body and return a real Promise.
    return consumeBody(self, inst, name);
}

/// Consume the body once: a second consume after `%used%` rejects (the WHATWG `bodyUsed` invariant).
/// Returns a real fulfilled/rejected Promise (`text` → string, `json` → JSON.parse, `arrayBuffer` →
/// ArrayBuffer).
fn consumeBody(self: *Interpreter, inst: *Object, name: []const u8) EvalError!Completion {
    const promise = try async_mod.newPromise(self);

    // Already used → reject with a TypeError.
    const used = inst.get("%used%") orelse Value{ .boolean = false };
    if (used == .boolean and used.boolean) {
        const tc = try self.throwError("TypeError", "Body is unusable: Body has already been read");
        try async_mod.rejectPromise(self, promise, tc.throw);
        return .{ .normal = .{ .object = promise } };
    }
    // Mark used.
    try inst.defineData("%used%", .{ .boolean = true }, false, true, true);

    const body_v = inst.get("%body%") orelse Value{ .string = "" };
    const bytes: []const u8 = if (body_v == .string) body_v.string else "";

    const eq = std.mem.eql;
    if (eq(u8, name, "text")) {
        try async_mod.fulfillPromise(self, promise, .{ .string = bytes });
    } else if (eq(u8, name, "json")) {
        const pc = try @import("builtin_json.zig").parse(self, &.{.{ .string = bytes }});
        if (pc.isAbrupt()) {
            try async_mod.rejectPromise(self, promise, pc.throw);
        } else {
            try async_mod.fulfillPromise(self, promise, pc.normal);
        }
    } else if (eq(u8, name, "arrayBuffer")) {
        const ab = try makeArrayBuffer(self, bytes);
        try async_mod.fulfillPromise(self, promise, .{ .object = ab });
    } else {
        try async_mod.fulfillPromise(self, promise, .undefined);
    }
    return .{ .normal = .{ .object = promise } };
}

/// `.clone()` — a fresh Response/Request with the same body bytes (does NOT mark the source used;
/// cloning a used body throws per the spec). First-cut: copies body + props via the ctor.
fn bodyClone(self: *Interpreter, inst: *Object, is_response: bool) EvalError!Completion {
    const used = inst.get("%used%") orelse Value{ .boolean = false };
    if (used == .boolean and used.boolean)
        return self.throwError("TypeError", "Body is unusable: Body has already been read");

    const body_v = inst.get("%body%") orelse Value.undefined;
    const headers_v = inst.get("headers") orelse Value.undefined;

    if (is_response) {
        const init = try Object.create(self.arena, self.objectProto());
        try init.defineData("status", inst.get("status") orelse .{ .number = 200 }, true, true, true);
        try init.defineData("statusText", inst.get("statusText") orelse .{ .string = "" }, true, true, true);
        try init.defineData("headers", headers_v, true, true, true);
        return makeResponseInstance(self, &.{ body_v, .{ .object = init } });
    }
    const init = try Object.create(self.arena, self.objectProto());
    try init.defineData("method", inst.get("method") orelse .{ .string = "GET" }, true, true, true);
    try init.defineData("headers", headers_v, true, true, true);
    if (body_v != .undefined) try init.defineData("body", body_v, true, true, true);
    const proto = self.globalProto("Request") orelse self.objectProto();
    const clone = try Object.create(self.arena, proto);
    return requestConstruct(self, .{ .object = clone }, &.{ inst.get("url") orelse Value{ .string = "" }, .{ .object = init } });
}
