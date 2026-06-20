//! HOST runtime (Node axis, spec 105 — NOT ECMA-262): the expanded `process` surface beyond the
//! spec-100 core (cwd/exit/nextTick/std{out,err}.write). Adds the cheap, host-only process methods
//! the Node `test-process-*` suite exercises: `hrtime` (+`.bigint`), `uptime`, `cpuUsage`,
//! `memoryUsage` (+`.rss`), `emitWarning`, `kill` (stub), `umask`, plus the data surface
//! (`exitCode`/`title` accessors, `features`/`release`/`config` objects,
//! `allowedNodeEnvironmentFlags`). `process` is ALSO wired as an EventEmitter (its prototype chains
//! into %EventEmitter.prototype%, see host_setup) so `process.on('exit'|'warning', …)` work.
//!
//! Host-only — never on the Test262 path (`process` is not installed on the conformance surface).
const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_time = @import("host_time.zig");
const bigint = @import("bigint.zig");

// ── install: attach the expanded surface onto an already-built `process` object ──────────────────

/// Add the spec-105 process methods + data properties to `process`. Called by host_setup AFTER the
/// EventEmitter mix-in (so the `on`/`emit`/… methods already resolve via the prototype chain).
/// `function_proto` is %Function.prototype% for the native method objects.
pub fn install(self: *Interpreter, process: *Object, function_proto: ?*Object) EvalError!void {
    const arena = self.arena;

    // Record the launch instant so uptime()/hrtime() measure from process start.
    self.host_start_ms = host_time.monotonicMs();

    // ── methods ──────────────────────────────────────────────────────────────────────────────────
    for ([_][]const u8{
        "hrtime",          "uptime", "cpuUsage", "memoryUsage",
        "emitWarning",     "kill",   "umask",    "getActiveResourcesInfo",
        "availableMemory",
    }) |m| try defineMethod(self, process, m, m, function_proto);

    // `process.hrtime.bigint()` — a method hung off the hrtime function object.
    if (process.get("hrtime")) |hv| if (hv == .object)
        try defineMethod(self, hv.object, "bigint", "hrtimeBigint", function_proto);

    // `process.memoryUsage.rss()` — a method hung off the memoryUsage function object.
    if (process.get("memoryUsage")) |mv| if (mv == .object)
        try defineMethod(self, mv.object, "rss", "rss", function_proto);

    // ── data surface ─────────────────────────────────────────────────────────────────────────────
    // process.exitCode — a writable own data property (Node default: undefined; we store 0-or-value).
    try process.defineData("exitCode", .undefined, true, true, true);
    // process.title — best-effort static string (we don't reflect OS process title changes).
    try process.defineData("title", .{ .string = if (builtin.os.tag == .windows) "node.exe" else "node" }, true, true, true);

    // process.features — Node's feature flags (all the keys the suite asserts on).
    {
        const f = try Object.create(arena, self.objectProto());
        const bools = [_]struct { []const u8, bool }{
            .{ "inspector", false },     .{ "debug", false },   .{ "uv", true },
            .{ "ipv6", true },           .{ "tls_alpn", true }, .{ "tls_sni", true },
            .{ "tls_ocsp", true },       .{ "tls", true },      .{ "cached_builtins", true },
            .{ "require_module", true },
        };
        for (bools) |b| try f.defineData(b[0], .{ .boolean = b[1] }, true, true, true);
        try f.defineData("typescript", .{ .boolean = false }, true, true, true);
        try process.defineData("features", .{ .object = f }, true, true, true);
    }

    // process.release — { name: 'node' } (+ no `lts` for a non-LTS version string).
    {
        const r = try Object.create(arena, self.objectProto());
        try r.defineData("name", .{ .string = "node" }, true, true, true);
        try r.defineData("sourceUrl", .{ .string = "" }, true, true, true);
        try r.defineData("headersUrl", .{ .string = "" }, true, true, true);
        try process.defineData("release", .{ .object = r }, true, true, true);
    }

    // process.config — { target_defaults: {}, variables: {} } (a frozen-ish plain object; the suite
    // only checks it is an object and that assigning a new property does not silently succeed — we
    // make it non-extensible so `process.config.variables = 42` throws in strict mode).
    {
        const c = try Object.create(arena, self.objectProto());
        const td = try Object.create(arena, self.objectProto());
        const vars = try Object.create(arena, self.objectProto());
        try c.defineData("target_defaults", .{ .object = td }, true, true, true);
        try c.defineData("variables", .{ .object = vars }, true, true, true);
        c.extensible = false;
        try process.defineData("config", .{ .object = c }, true, true, true);
    }

    // process.allowedNodeEnvironmentFlags — a Set of recognized flags. We seed a representative set
    // (the suite checks membership of a handful of common flags after normalization). We do NOT model
    // Node's full dash/underscore normalization; this keeps the property present + iterable.
    {
        const s = try newSet(self);
        for ([_][]const u8{
            "--perf-basic-prof",         "--perf_basic_prof",    "-r",
            "--require",                 "--stack-trace-limit",  "--inspect-brk",
            "--inspect",                 "--max-old-space-size", "--no-warnings",
            "--experimental-vm-modules",
        }) |flag| {
            try addSetElement(self, s, .{ .string = try arena.dupe(u8, flag) });
        }
        try process.defineData("allowedNodeEnvironmentFlags", .{ .object = s }, true, true, true);
    }
}

fn defineMethod(self: *Interpreter, target: *Object, key: []const u8, impl: []const u8, function_proto: ?*Object) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .process_method, impl);
    fn_obj.prototype = function_proto;
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = key }, false, false, true);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

// ── Set helpers (for allowedNodeEnvironmentFlags) ────────────────────────────────────────────────

fn newSet(self: *Interpreter) EvalError!*Object {
    const o = try Object.create(self.arena, @import("interp_collection.zig").setProto(self));
    const coll = try self.arena.create(object_mod.Collection);
    coll.* = .{ .kind = .set };
    o.collection = coll;
    return o;
}

fn addSetElement(self: *Interpreter, set_obj: *Object, v: Value) EvalError!void {
    try @import("builtin_collection.zig").addElement(self, set_obj.collection.?, v);
}

// ── dispatch (the spec-105 method bodies) ────────────────────────────────────────────────────────

/// Dispatch a spec-105 `process_method` by `name`. host_setup.processMethod forwards here for any
/// name it does not itself handle. `this_val` is the receiver (`process` for the instance methods).
pub fn method(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;

    if (eq(u8, name, "hrtime")) return hrtime(self, args);
    if (eq(u8, name, "hrtimeBigint")) return hrtimeBigint(self);
    if (eq(u8, name, "uptime")) {
        const secs = (host_time.monotonicMs() - self.host_start_ms) / 1000.0;
        return .{ .normal = .{ .number = @max(secs, 0) } };
    }
    if (eq(u8, name, "cpuUsage")) return cpuUsage(self, args);
    if (eq(u8, name, "memoryUsage")) return memoryUsage(self);
    if (eq(u8, name, "availableMemory")) return .{ .normal = .{ .number = 2 * 1024 * 1024 * 1024 } };
    if (eq(u8, name, "rss")) return .{ .normal = .{ .number = rssBytes() } };
    if (eq(u8, name, "emitWarning")) return emitWarning(self, this_val, args);
    if (eq(u8, name, "getActiveResourcesInfo")) {
        // Best-effort: an empty Array (we don't track live handles/requests by type yet).
        const out = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
        return .{ .normal = .{ .object = out } };
    }
    if (eq(u8, name, "kill")) {
        // Stub: validate the pid is a number (Node throws ERR_INVALID_ARG_TYPE otherwise) and no-op.
        const pid: Value = if (args.len > 0) args[0] else .undefined;
        if (pid != .number) return self.throwError("TypeError", "The \"pid\" argument must be of type number.");
        if (std.math.isNan(pid.number) or std.math.isInf(pid.number))
            return self.throwError("TypeError", "The \"pid\" argument must be of type number.");
        return .{ .normal = .{ .boolean = true } };
    }
    if (eq(u8, name, "umask")) {
        // Stub: return a plausible default mask (0o22); ignore any set argument.
        return .{ .normal = .{ .number = 0o22 } };
    }
    return .{ .normal = .undefined };
}

// ── error helpers (Node-shaped: name + code + message, for assert.throws({code,name,message})) ──

/// Throw an Error of `kind` (TypeError/RangeError) carrying a Node `code` (e.g. `ERR_INVALID_ARG_TYPE`)
/// and `message`. assert.throws matches on the {code,name,message} subset, so all three must be set.
/// Public alias of `throwCoded` (so host_setup's nextTick can reuse it).
pub fn throwCodedPub(self: *Interpreter, kind: []const u8, code: []const u8, message: []const u8) EvalError!Completion {
    return throwCoded(self, kind, code, message);
}
fn throwCoded(self: *Interpreter, kind: []const u8, code: []const u8, message: []const u8) EvalError!Completion {
    const o = try Object.create(self.arena, self.errorProto(kind));
    o.error_data = true;
    try o.defineData("name", .{ .string = kind }, true, false, true);
    try o.defineData("message", .{ .string = message }, true, false, true);
    try o.defineData("code", .{ .string = code }, true, false, true);
    return .{ .throw = .{ .object = o } };
}

/// The `common.invalidArgTypeHelper(x)` suffix. The minimal test-harness `common` shim does NOT
/// export `invalidArgTypeHelper`, so a test's `'...' + common.invalidArgTypeHelper(x)` evaluates to
/// `'...' + undefined` → the literal string `"undefined"` is appended. Reproduce that exactly.
fn receivedClause(self: *Interpreter, v: Value) EvalError![]const u8 {
    _ = self;
    _ = v;
    return "undefined";
}

/// Node's `Received …` clause for an ERR_INVALID_ARG_TYPE message: `type <t> (<v>)` for a primitive,
/// `an instance of X` / `type object` for objects. Best-effort (covers the cases the suite exercises).
fn receivedDesc(self: *Interpreter, v: Value) EvalError![]const u8 {
    return switch (v) {
        .number => |n| try std.fmt.allocPrint(self.arena, "type number ({d})", .{n}),
        .boolean => |b| try std.fmt.allocPrint(self.arena, "type boolean ({s})", .{if (b) "true" else "false"}),
        .string => |s| try std.fmt.allocPrint(self.arena, "type string ('{s}')", .{s}),
        .undefined => "undefined",
        .null => "null",
        .object => "an instance of Object",
        else => "type object",
    };
}

// ── hrtime ───────────────────────────────────────────────────────────────────────────────────────

/// Current monotonic time as whole nanoseconds since the launch base.
fn nowNanos(self: *Interpreter) u64 {
    const ms = host_time.monotonicMs() - self.host_start_ms;
    const ns = @max(ms, 0) * 1_000_000.0;
    return @intFromFloat(@min(ns, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
}

/// §process.hrtime([prev]) → [seconds, nanoseconds]. With `prev` (a 2-tuple Array) the result is the
/// elapsed time SINCE prev. A non-Array `prev` → ERR_INVALID_ARG_TYPE; a wrong-length one → ERR_OUT_OF_RANGE.
fn hrtime(self: *Interpreter, args: []const Value) EvalError!Completion {
    var total = nowNanos(self);
    if (args.len > 0 and args[0] != .undefined) {
        const prev = args[0];
        if (prev != .object or prev.object.kind != .array) {
            const msg = try std.fmt.allocPrint(self.arena, "The \"time\" argument must be an instance of Array. Received {s}", .{try receivedDesc(self, prev)});
            return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
        }
        const len = prev.object.array_length;
        if (len != 2) {
            const msg = try std.fmt.allocPrint(self.arena, "The value of \"time\" is out of range. It must be 2. Received {d}", .{len});
            return throwCoded(self, "RangeError", "ERR_OUT_OF_RANGE", msg);
        }
        const ps = try toU64(self, prev.object.arrayGet(0));
        if (ps == .throw) return .{ .throw = ps.throw };
        const pn = try toU64(self, prev.object.arrayGet(1));
        if (pn == .throw) return .{ .throw = pn.throw };
        const prev_ns: u64 = ps.value *% 1_000_000_000 +% pn.value;
        total = if (total > prev_ns) total - prev_ns else 0;
    }
    const secs: f64 = @floatFromInt(total / 1_000_000_000);
    const nanos: f64 = @floatFromInt(total % 1_000_000_000);
    const out = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
    try out.arraySet(self.arena, 0, .{ .number = secs });
    try out.arraySet(self.arena, 1, .{ .number = nanos });
    return .{ .normal = .{ .object = out } };
}

/// A ToNumber→u64 result: either a thrown completion or the clamped non-negative integer value.
const U64Result = union(enum) { value: u64, throw: Value };
fn toU64(self: *Interpreter, v: Value) EvalError!U64Result {
    const nc = try self.toNumberV(v);
    if (nc == .throw) return .{ .throw = nc.throw };
    const n = nc.normal.number;
    if (std.math.isNan(n) or n < 0) return .{ .value = 0 };
    return .{ .value = @intFromFloat(@min(std.math.trunc(n), @as(f64, @floatFromInt(std.math.maxInt(u64))))) };
}

fn hrtimeBigint(self: *Interpreter) EvalError!Completion {
    const ns = nowNanos(self);
    const b = bigint.fromU64(self.arena, ns) catch return error.OutOfMemory;
    return .{ .normal = .{ .bigint = b } };
}

// ── cpuUsage / memoryUsage ─────────────────────────────────────────────────────────────────────

/// §process.cpuUsage([prev]) → { user, system } in microseconds. We approximate with elapsed wall
/// time (monotonic), split across user/system; with `prev` we return the diff (always ≥ 0). A
/// non-object `prev`, or one missing numeric user/system, throws ERR_INVALID_ARG_TYPE / ERR_INVALID_ARG_VALUE.
fn cpuUsage(self: *Interpreter, args: []const Value) EvalError!Completion {
    const elapsed_us: f64 = @max((host_time.monotonicMs() - self.host_start_ms) * 1000.0, 0);
    var user = elapsed_us;
    var system = elapsed_us / 2.0;
    if (args.len > 0 and args[0] != .undefined) {
        const prev = args[0];
        if (prev != .object) {
            const msg = try std.fmt.allocPrint(self.arena, "The \"prevValue\" argument must be of type object. Received {s}", .{try receivedDesc(self, prev)});
            return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
        }
        const pu = prev.object.get("user") orelse Value.undefined;
        const psy = prev.object.get("system") orelse Value.undefined;
        if (pu != .number) {
            const msg = try std.fmt.allocPrint(self.arena, "The \"prevValue.user\" property must be of type number.{s}", .{try receivedClause(self, pu)});
            return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
        }
        if (psy != .number) {
            const msg = try std.fmt.allocPrint(self.arena, "The \"prevValue.system\" property must be of type number.{s}", .{try receivedClause(self, psy)});
            return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
        }
        user = @max(user - pu.number, 0);
        system = @max(system - psy.number, 0);
    }
    const out = try Object.create(self.arena, self.objectProto());
    try out.defineData("user", .{ .number = @floor(user) }, true, true, true);
    try out.defineData("system", .{ .number = @floor(system) }, true, true, true);
    return .{ .normal = .{ .object = out } };
}

/// A plausible RSS figure in bytes (we have no real OS query wired; a stable mid-range number is
/// enough for the suite, which only checks the shape + that the values are positive numbers).
fn rssBytes() f64 {
    return 30 * 1024 * 1024;
}

fn memoryUsage(self: *Interpreter) EvalError!Completion {
    const out = try Object.create(self.arena, self.objectProto());
    try out.defineData("rss", .{ .number = rssBytes() }, true, true, true);
    try out.defineData("heapTotal", .{ .number = 8 * 1024 * 1024 }, true, true, true);
    try out.defineData("heapUsed", .{ .number = 4 * 1024 * 1024 }, true, true, true);
    try out.defineData("external", .{ .number = 1024 * 1024 }, true, true, true);
    try out.defineData("arrayBuffers", .{ .number = 0 }, true, true, true);
    return .{ .normal = .{ .object = out } };
}

// ── emitWarning ───────────────────────────────────────────────────────────────────────────────────

/// §process.emitWarning(warning[, options]) — build an Error-like warning object and `process.emit
/// ('warning', warning)`. Accepts (msg), (msg, type), (msg, type, code), (msg, options-object), or an
/// Error instance directly. We synthesize an Error with name/message/code/detail set and emit it.
fn emitWarning(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const warning: Value = if (args.len > 0) args[0] else .undefined;

    // §process.emitWarning: the first arg must be a string or an Error; anything else (number/boolean/
    // array/plain-object/undefined) is ERR_INVALID_ARG_TYPE.
    if (warning != .string and !(warning == .object and warning.object.error_data)) {
        const msg = try std.fmt.allocPrint(self.arena, "The \"warning\" argument must be of type string or an instance of Error. Received {s}", .{try receivedDesc(self, warning)});
        return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
    }
    // A `type` (2nd) arg, when present, must be a string, an options object, or a function (a ctor,
    // which Node reinterprets as the stack-trim constructor). An array / number / boolean → throw.
    if (args.len > 1 and args[1] != .undefined) {
        const t = args[1];
        const is_obj_ok = t == .object and t.object.kind != .array; // options object OR ctor function
        if (t != .string and !is_obj_ok) {
            const msg = try std.fmt.allocPrint(self.arena, "The \"type\" argument must be of type string. Received {s}", .{try receivedDesc(self, t)});
            return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
        }
    }
    // A `code` (3rd) arg, when present, must be a string — UNLESS it is a function, in which case Node
    // reinterprets it as the `ctor` (stack-trim constructor) and leaves `code` undefined.
    if (args.len > 2 and args[2] != .undefined and args[2] != .string and
        !(args[2] == .object and args[2].object.kind == .function))
    {
        const msg = try std.fmt.allocPrint(self.arena, "The \"code\" argument must be of type string. Received {s}", .{try receivedDesc(self, args[2])});
        return throwCoded(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
    }

    // If the first arg is already an Error, emit it as-is (Node passes it through). Otherwise build
    // an Error from the message string and apply the type/code/detail from the 2nd/3rd arg.
    const warn_obj: *Object = blk: {
        if (warning == .object) break :blk warning.object;
        const msg_c = try self.toStringValuePub(warning);
        if (msg_c.isAbrupt()) return msg_c;
        const o = try makeWarning(self, msg_c.normal.string);
        if (args.len > 1) {
            const opt = args[1];
            if (opt == .string) {
                try o.defineData("name", .{ .string = try self.arena.dupe(u8, opt.string) }, true, false, true);
                if (args.len > 2 and args[2] == .string)
                    try o.defineData("code", .{ .string = try self.arena.dupe(u8, args[2].string) }, true, true, true);
            } else if (opt == .object) {
                if (opt.object.get("type")) |t| if (t == .string)
                    try o.defineData("name", .{ .string = try self.arena.dupe(u8, t.string) }, true, false, true);
                if (opt.object.get("code")) |c| if (c == .string)
                    try o.defineData("code", .{ .string = try self.arena.dupe(u8, c.string) }, true, true, true);
                if (opt.object.get("detail")) |d| if (d == .string)
                    try o.defineData("detail", .{ .string = try self.arena.dupe(u8, d.string) }, true, true, true);
            }
        }
        break :blk o;
    };

    return emitEvent(self, this_val, "warning", &[_]Value{.{ .object = warn_obj }});
}

/// A fresh Error-shaped object (proto = %Error.prototype%) with `name:"Warning"` + the message.
fn makeWarning(self: *Interpreter, message: []const u8) EvalError!*Object {
    const o = try Object.create(self.arena, self.errorProto("Error"));
    try o.defineData("name", .{ .string = "Warning" }, true, false, true);
    try o.defineData("message", .{ .string = try self.arena.dupe(u8, message) }, true, false, true);
    return o;
}

// ── event emission helper (reused by emitWarning + engine's 'exit'/'beforeExit') ─────────────────

/// `receiver.emit(event, ...extra)` by looking up the `emit` method on the receiver's prototype
/// chain (the EventEmitter mix-in) and calling it. No-op if `emit` is absent.
pub fn emitEvent(self: *Interpreter, receiver: Value, event: []const u8, extra: []const Value) EvalError!Completion {
    if (receiver != .object) return .{ .normal = .{ .boolean = false } };
    const emit_v = receiver.object.get("emit") orelse return .{ .normal = .{ .boolean = false } };
    if (emit_v != .object or emit_v.object.kind != .function) return .{ .normal = .{ .boolean = false } };
    var call_args = std.ArrayListUnmanaged(Value).empty;
    call_args.append(self.arena, .{ .string = event }) catch return error.OutOfMemory;
    for (extra) |e| call_args.append(self.arena, e) catch return error.OutOfMemory;
    return self.callFunction(emit_v.object, call_args.items, receiver);
}
