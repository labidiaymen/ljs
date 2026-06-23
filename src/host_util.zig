//! HOST runtime (Node axis, spec 103 Unit B — NOT ECMA-262): Node's `util` core module —
//! `require('util')`. Provides `format`, `inspect`, `promisify`, `inherits`, `deprecate`, and a
//! `types` predicate object. Installed host-only via the `host_require` core-module registry; never
//! on the Test262 engine surface (host globals are not installed there).
//!
//! Mechanics mirror the other host modules: the module's exports are a plain object of
//! `.util_method` natives (built once per run, cached by `host_require`). Per-instance state for the
//! `promisify` wrapper / its callback (and `deprecate`) rides on hidden own `"%…%"` properties read
//! off `func` in dispatch (`callNative` hands us `func`).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const async_mod = @import("interp_async.zig");

const eql = std.mem.eql;

// ── build ──────────────────────────────────────────────────────────────────────

/// Build the `util` module exports object (the `.core_module_cache` caller caches it).
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());

    for ([_][]const u8{
        "format",                   "formatWithOptions", "inspect",   "promisify",
        "callbackify",              "inherits",          "deprecate", "isDeepStrictEqual",
        "stripVTControlCharacters",
    }) |m|
        try defineMethod(self, obj, m);

    // util.types — a sub-object of predicate natives.
    const types = try Object.create(arena, self.objectProto());
    for ([_][]const u8{
        "isDate",            "isRegExp",               "isNativeError",   "isPromise",
        "isArrayBuffer",     "isTypedArray",           "isMap",           "isSet",
        "isAsyncFunction",   "isGeneratorFunction",    "isWeakMap",       "isWeakSet",
        "isDataView",        "isProxy",                "isBooleanObject", "isNumberObject",
        "isStringObject",    "isSymbolObject",         "isBigIntObject",  "isSharedArrayBuffer",
        "isAnyArrayBuffer",  "isBoxedPrimitive",       "isMapIterator",   "isSetIterator",
        "isGeneratorObject", "isAsyncGeneratorObject",
    }) |m|
        try defineMethod(self, types, m);
    try obj.defineData("types", .{ .object = types }, true, true, true);

    return obj;
}

fn defineMethod(self: *Interpreter, target: *Object, name: []const u8) EvalError!void {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .util_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, true, true);
}

// ── dispatch ────────────────────────────────────────────────────────────────────

/// Dispatch a `.util_method` native by its `native_name` (or by its hidden per-instance state for
/// the promisify/deprecate wrappers).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    _ = this_val;
    const name = func.native_name;

    // The promisify wrapper / its callback / the deprecate wrapper are `.util_method` natives
    // distinguished by a hidden own state property.
    if (func.get("%promisify_fn%") != null) return promisifyWrapper(self, func, args);
    if (func.get("%promisify_promise%") != null) return promisifyCallback(self, func, args);
    if (func.get("%callbackify_fn%") != null) return callbackifyWrapper(self, func, args);
    if (func.get("%callbackify_cb%") != null) return callbackifyReaction(self, func, args);
    if (func.get("%deprecated_fn%") != null) return deprecateWrapper(self, func, args);

    if (eql(u8, name, "stripVTControlCharacters")) return stripVT(self, args);
    if (eql(u8, name, "format")) return format(self, args, 0);
    if (eql(u8, name, "formatWithOptions")) return format(self, args, 1);
    if (eql(u8, name, "inspect")) {
        const v: Value = if (args.len > 0) args[0] else .undefined;
        const s = try inspectValue(self, v, 0, false);
        return .{ .normal = .{ .string = s } };
    }
    if (eql(u8, name, "promisify")) return promisify(self, args);
    if (eql(u8, name, "callbackify")) return callbackify(self, args);
    if (eql(u8, name, "inherits")) return inherits(self, args);
    if (eql(u8, name, "deprecate")) return deprecate(self, args);
    if (eql(u8, name, "isDeepStrictEqual")) {
        const a: Value = if (args.len > 0) args[0] else .undefined;
        const b: Value = if (args.len > 1) args[1] else .undefined;
        return .{ .normal = .{ .boolean = try deepEqual(self, a, b) } };
    }
    // util.types.* predicates.
    return typesPredicate(name, args);
}

/// `util.stripVTControlCharacters(str)` — remove ANSI/VT escape sequences (color codes etc.). Handles
/// CSI (`ESC [ … final-byte`), OSC (`ESC ] … BEL|ST`), and 2-byte (`ESC <byte>`) forms. Used by commander
/// (and other CLIs) to measure printed width.
fn stripVT(self: *Interpreter, args: []const Value) EvalError!Completion {
    const sc = try self.toStringValuePub(if (args.len > 0) args[0] else .{ .string = "" });
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len) {
            const next = s[i + 1];
            if (next == '[') { // CSI: ESC [ … final byte 0x40..0x7e
                i += 2;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) : (i += 1) {}
                if (i < s.len) i += 1;
                continue;
            } else if (next == ']') { // OSC: ESC ] … BEL (0x07) or ST (ESC \)
                i += 2;
                while (i < s.len and s[i] != 0x07 and !(s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\')) : (i += 1) {}
                if (i < s.len and s[i] == 0x1b) i += 1;
                if (i < s.len) i += 1;
                continue;
            } else { // ESC + single byte
                i += 2;
                continue;
            }
        }
        out.append(self.arena, s[i]) catch return error.OutOfMemory;
        i += 1;
    }
    return .{ .normal = .{ .string = out.items } };
}

// ── format ──────────────────────────────────────────────────────────────────────

/// `util.format(fmt, ...args)` — substitute %s/%d/%i/%f/%j/%o/%O/%% in `fmt`; leftover args are
/// appended space-separated. `arg_start` skips a leading options object (formatWithOptions).
fn format(self: *Interpreter, all_args: []const Value, arg_start: usize) EvalError!Completion {
    const arena = self.arena;
    const args = if (all_args.len > arg_start) all_args[arg_start..] else all_args[all_args.len..];
    var out: std.ArrayListUnmanaged(u8) = .empty;

    if (args.len == 0) return .{ .normal = .{ .string = "" } };

    var arg_i: usize = 1; // args[0] is the format target.
    const fmt0 = args[0];

    if (fmt0 == .string) {
        const f = fmt0.string;
        var i: usize = 0;
        while (i < f.len) {
            const c = f[i];
            if (c == '%' and i + 1 < f.len) {
                const spec = f[i + 1];
                switch (spec) {
                    '%' => {
                        out.append(arena, '%') catch return error.OutOfMemory;
                        i += 2;
                        continue;
                    },
                    's', 'd', 'i', 'f', 'j', 'o', 'O', 'c' => {
                        if (arg_i < args.len) {
                            const a = args[arg_i];
                            arg_i += 1;
                            const piece = try formatOne(self, spec, a);
                            out.appendSlice(arena, piece) catch return error.OutOfMemory;
                        } else {
                            // No matching arg → emit the directive literally.
                            out.append(arena, '%') catch return error.OutOfMemory;
                            out.append(arena, spec) catch return error.OutOfMemory;
                        }
                        i += 2;
                        continue;
                    },
                    else => {},
                }
            }
            out.append(arena, c) catch return error.OutOfMemory;
            i += 1;
        }
    } else {
        // Non-string first arg → inspect it.
        const s = try inspectValue(self, fmt0, 0, false);
        out.appendSlice(arena, s) catch return error.OutOfMemory;
    }

    // Append leftover args, space-separated.
    while (arg_i < args.len) : (arg_i += 1) {
        out.append(arena, ' ') catch return error.OutOfMemory;
        const a = args[arg_i];
        const piece = if (a == .string) a.string else try inspectValue(self, a, 0, false);
        out.appendSlice(arena, piece) catch return error.OutOfMemory;
    }

    return .{ .normal = .{ .string = out.items } };
}

/// Render one format directive's argument.
fn formatOne(self: *Interpreter, spec: u8, a: Value) EvalError![]const u8 {
    const arena = self.arena;
    switch (spec) {
        's' => {
            // %s: strings as-is; objects via inspect; other primitives via String().
            if (a == .string) return a.string;
            if (a == .object) return inspectValue(self, a, 0, false);
            const sc = try self.toStringValuePub(a);
            if (sc.isAbrupt()) return "";
            return sc.normal.string;
        },
        'd', 'i' => {
            const n = try toNumber(self, a);
            if (std.math.isNan(n)) return "NaN";
            const t = std.math.trunc(n);
            return numToString(arena, t);
        },
        'f' => {
            const n = try toNumber(self, a);
            return numToString(arena, n);
        },
        'j' => return jsonStringify(self, a),
        'o', 'O' => return inspectValue(self, a, 0, false),
        'c' => return "", // CSS directive — consumed, renders nothing.
        else => return "",
    }
}

fn numToString(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == std.math.trunc(n) and @abs(n) < 1e21) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(arena, "{d}", .{n}) catch error.OutOfMemory;
}

fn toNumber(self: *Interpreter, v: Value) EvalError!f64 {
    _ = self;
    return switch (v) {
        .number => v.number,
        .boolean => if (v.boolean) 1 else 0,
        .null => 0,
        .undefined => std.math.nan(f64),
        .string => std.fmt.parseFloat(f64, std.mem.trim(u8, v.string, " \t\r\n")) catch std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

fn jsonStringify(self: *Interpreter, v: Value) EvalError![]const u8 {
    const g = self.globals orelse return "undefined";
    const json_b = g.lookup("JSON") orelse return "undefined";
    if (json_b.value != .object) return "undefined";
    const sv = json_b.value.object.get("stringify") orelse return "undefined";
    if (sv != .object) return "undefined";
    const c = try self.callFunction(sv.object, &.{v}, json_b.value);
    if (c.isAbrupt()) return "undefined";
    if (c.normal == .string) return c.normal.string;
    return "undefined";
}

// ── inspect ─────────────────────────────────────────────────────────────────────

/// `util.inspect(value)` — a readable rendering. `depth` is the current nesting depth (~2 max);
/// `quoted` requests string quoting (true for strings nested inside a container).
fn inspectValue(self: *Interpreter, v: Value, depth: usize, quoted: bool) EvalError![]const u8 {
    const arena = self.arena;
    switch (v) {
        .undefined => return "undefined",
        .null => return "null",
        .boolean => return if (v.boolean) "true" else "false",
        .number => return numToString(arena, v.number),
        .string => {
            if (!quoted) return v.string;
            return std.fmt.allocPrint(arena, "'{s}'", .{v.string}) catch error.OutOfMemory;
        },
        .symbol => {
            const desc = v.symbol.description orelse "";
            return std.fmt.allocPrint(arena, "Symbol({s})", .{desc}) catch error.OutOfMemory;
        },
        .object => return inspectObject(self, v.object, depth),
        else => {
            const sc = try self.toStringValuePub(v);
            if (sc.isAbrupt()) return "";
            return sc.normal.string;
        },
    }
}

fn inspectObject(self: *Interpreter, obj: *Object, depth: usize) EvalError![]const u8 {
    const arena = self.arena;

    // Functions → [Function: name] / [Function (anonymous)].
    if (obj.kind == .function) {
        const nm = funcName(obj);
        if (nm.len == 0) return "[Function (anonymous)]";
        return std.fmt.allocPrint(arena, "[Function: {s}]", .{nm}) catch error.OutOfMemory;
    }
    // RegExp → /source/flags.
    if (obj.regexp != null) {
        const sc = try self.getProperty(.{ .object = obj }, "source");
        const fc = try self.getProperty(.{ .object = obj }, "flags");
        const src = if (!sc.isAbrupt() and sc.normal == .string) sc.normal.string else "";
        const flg = if (!fc.isAbrupt() and fc.normal == .string) fc.normal.string else "";
        return std.fmt.allocPrint(arena, "/{s}/{s}", .{ src, flg }) catch error.OutOfMemory;
    }
    // Date → ISO string.
    if (obj.date_value != null) {
        const c = try self.getProperty(.{ .object = obj }, "toISOString");
        if (!c.isAbrupt() and c.normal == .object) {
            const r = try self.callFunction(c.normal.object, &.{}, .{ .object = obj });
            if (!r.isAbrupt() and r.normal == .string) return r.normal.string;
        }
        return "[Date]";
    }
    // Error → its toString (e.g. "Error: boom").
    if (obj.error_data) {
        const sc = try self.toStringValuePub(.{ .object = obj });
        if (!sc.isAbrupt() and sc.normal == .string) return sc.normal.string;
        return "[Error]";
    }

    // Depth limit: beyond ~2 levels, summarize.
    if (depth > 2) {
        if (obj.kind == .array) return "[Array]";
        return "[Object]";
    }

    // Arrays → [ a, b, c ].
    if (obj.kind == .array) {
        const len = obj.arrayLen();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(arena, "[") catch return error.OutOfMemory;
        var i: usize = 0;
        var first = true;
        while (i < len) : (i += 1) {
            if (!first) out.appendSlice(arena, ",") catch return error.OutOfMemory;
            out.append(arena, ' ') catch return error.OutOfMemory;
            first = false;
            const ev = obj.arrayGet(i);
            const s = try inspectValue(self, ev, depth + 1, true);
            out.appendSlice(arena, s) catch return error.OutOfMemory;
        }
        if (!first) out.append(arena, ' ') catch return error.OutOfMemory;
        out.appendSlice(arena, "]") catch return error.OutOfMemory;
        return out.items;
    }

    // Plain object → { k: v, … } over own enumerable string-keyed props.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(arena, "{") catch return error.OutOfMemory;
    var first = true;
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable) continue;
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '%') continue; // skip hidden host state
        if (!first) out.appendSlice(arena, ",") catch return error.OutOfMemory;
        out.append(arena, ' ') catch return error.OutOfMemory;
        first = false;
        if (isIdentifier(key)) {
            out.appendSlice(arena, key) catch return error.OutOfMemory;
        } else {
            const qk = std.fmt.allocPrint(arena, "'{s}'", .{key}) catch return error.OutOfMemory;
            out.appendSlice(arena, qk) catch return error.OutOfMemory;
        }
        out.appendSlice(arena, ": ") catch return error.OutOfMemory;
        const sv = switch (pv.payload) {
            .data => try inspectValue(self, pv.payload.data, depth + 1, true),
            .accessor => "[Getter/Setter]",
        };
        out.appendSlice(arena, sv) catch return error.OutOfMemory;
    }
    if (!first) out.append(arena, ' ') catch return error.OutOfMemory;
    out.appendSlice(arena, "}") catch return error.OutOfMemory;
    return out.items;
}

fn funcName(obj: *Object) []const u8 {
    if (obj.get("name")) |nv| if (nv == .string) return nv.string;
    if (obj.native_name.len > 0) return obj.native_name;
    return "";
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or
            (i > 0 and c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

// ── promisify ───────────────────────────────────────────────────────────────────

/// `util.promisify(fn)` → a function that, when called, returns a Promise and invokes
/// `fn(...args, callback)` where `callback(err, value)` settles the promise.
fn promisify(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const fn_v: Value = if (args.len > 0) args[0] else .undefined;
    if (fn_v != .object or fn_v.object.kind != .function) {
        return self.throwError("TypeError", "The \"original\" argument must be of type function");
    }
    const wrapper = try Object.createNative(arena, .util_method, "");
    wrapper.prototype = self.functionProto();
    _ = wrapper.properties.orderedRemove("prototype");
    // Hidden own state: the wrapped function (its presence flags this native as the wrapper).
    try wrapper.defineData("%promisify_fn%", fn_v, false, false, true);
    try wrapper.defineData("name", .{ .string = "" }, false, false, true);
    return .{ .normal = .{ .object = wrapper } };
}

/// The promisify wrapper's behavior: make a Promise, build a settling callback carrying it, call the
/// original `fn(...args, callback)`. A synchronous throw of `fn` rejects the promise.
fn promisifyWrapper(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const fn_v = func.get("%promisify_fn%") orelse return self.throwError("TypeError", "promisify: missing original");
    if (fn_v != .object) return self.throwError("TypeError", "promisify: original not callable");

    const promise = try async_mod.newPromise(self);

    // Build the (err, value) callback native carrying the promise.
    const cb = try Object.createNative(arena, .util_method, "");
    cb.prototype = self.functionProto();
    _ = cb.properties.orderedRemove("prototype");
    try cb.defineData("%promisify_promise%", .{ .object = promise }, false, false, true);

    // call_args = [...args, cb].
    var call_args: std.ArrayListUnmanaged(Value) = .empty;
    call_args.appendSlice(arena, args) catch return error.OutOfMemory;
    call_args.append(arena, .{ .object = cb }) catch return error.OutOfMemory;

    const c = try self.callFunction(fn_v.object, call_args.items, .undefined);
    if (c == .throw) {
        // A synchronous throw rejects the promise (Node wraps it).
        try async_mod.rejectPromise(self, promise, c.throw);
    }
    return .{ .normal = .{ .object = promise } };
}

/// The settling callback: `(err, value)` → reject on a truthy `err`, else resolve with `value`.
fn promisifyCallback(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const pv = func.get("%promisify_promise%") orelse return .{ .normal = .undefined };
    if (pv != .object) return .{ .normal = .undefined };
    const promise = pv.object;
    const err: Value = if (args.len > 0) args[0] else .undefined;
    if (truthy(err)) {
        try async_mod.rejectPromise(self, promise, err);
    } else {
        const res: Value = if (args.len > 1) args[1] else .undefined;
        try async_mod.resolvePromise(self, promise, res);
    }
    return .{ .normal = .undefined };
}

fn truthy(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => v.boolean,
        .number => v.number != 0 and !std.math.isNan(v.number),
        .string => v.string.len > 0,
        else => true,
    };
}

// ── callbackify ─────────────────────────────────────────────────────────────────

/// `util.callbackify(original)` → the inverse of promisify: a function `(...args, callback)` that
/// calls `original(...args)`, awaits the returned promise, and invokes `callback(err, value)` —
/// `callback(null, value)` on fulfill, `callback(reason)` on reject.
fn callbackify(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const fn_v: Value = if (args.len > 0) args[0] else .undefined;
    if (fn_v != .object or fn_v.object.kind != .function)
        return self.throwError("TypeError", "The \"original\" argument must be of type function");
    const wrapper = try Object.createNative(arena, .util_method, "");
    wrapper.prototype = self.functionProto();
    _ = wrapper.properties.orderedRemove("prototype");
    try wrapper.defineData("%callbackify_fn%", fn_v, false, false, true);
    try wrapper.defineData("name", .{ .string = "" }, false, false, true);
    return .{ .normal = .{ .object = wrapper } };
}

/// The callbackify wrapper's behavior: the LAST argument is the node-style callback; call the
/// original with the rest, coerce its result to a Promise, and settle the callback off the promise's
/// fulfill/reject reactions. A non-function trailing callback throws (Node's contract).
fn callbackifyWrapper(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const fn_v = func.get("%callbackify_fn%") orelse return self.throwError("TypeError", "callbackify: missing original");
    if (fn_v != .object) return self.throwError("TypeError", "callbackify: original not callable");
    if (args.len == 0 or args[args.len - 1] != .object or args[args.len - 1].object.kind != .function)
        return self.throwError("TypeError", "The last argument must be of type function");

    const cb = args[args.len - 1];
    const fwd = args[0 .. args.len - 1];

    // Call original(...fwd). A synchronous throw becomes the rejection path.
    const c = try self.callFunction(fn_v.object, fwd, .undefined);
    const promise = try async_mod.newPromise(self);
    if (c == .throw) {
        try async_mod.rejectPromise(self, promise, c.throw);
    } else {
        // Coerce the returned value (promise / thenable / plain) into our promise.
        try async_mod.resolvePromise(self, promise, c.normal);
    }

    // fulfill reaction → cb(null, value); reject reaction → cb(reason).
    const on_fulfill = try Object.createNative(arena, .util_method, "");
    on_fulfill.prototype = self.functionProto();
    _ = on_fulfill.properties.orderedRemove("prototype");
    try on_fulfill.defineData("%callbackify_cb%", cb, false, false, true);
    try on_fulfill.defineData("%callbackify_reject%", .{ .boolean = false }, false, false, true);

    const on_reject = try Object.createNative(arena, .util_method, "");
    on_reject.prototype = self.functionProto();
    _ = on_reject.properties.orderedRemove("prototype");
    try on_reject.defineData("%callbackify_cb%", cb, false, false, true);
    try on_reject.defineData("%callbackify_reject%", .{ .boolean = true }, false, false, true);

    try async_mod.performPromiseThen(self, promise, on_fulfill, on_reject, null);
    return .{ .normal = .undefined };
}

/// A callbackify reaction: invoke the carried node-style callback. The fulfill reaction (its
/// `%callbackify_reject%` is false) calls `cb(null, value)`; the reject reaction calls `cb(reason)`.
fn callbackifyReaction(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const cb_v = func.get("%callbackify_cb%") orelse return .{ .normal = .undefined };
    if (cb_v != .object) return .{ .normal = .undefined };
    const is_reject = blk: {
        const r = func.get("%callbackify_reject%") orelse break :blk false;
        break :blk r == .boolean and r.boolean;
    };
    const settle: Value = if (args.len > 0) args[0] else .undefined;

    var call_args: std.ArrayListUnmanaged(Value) = .empty;
    if (is_reject) {
        call_args.append(arena, settle) catch return error.OutOfMemory;
    } else {
        call_args.append(arena, .null) catch return error.OutOfMemory;
        call_args.append(arena, settle) catch return error.OutOfMemory;
    }
    return self.callFunction(cb_v.object, call_args.items, .undefined);
}

// ── inherits ────────────────────────────────────────────────────────────────────

/// `util.inherits(ctor, superCtor)` — set `ctor.super_ = superCtor` and
/// `ctor.prototype = Object.create(superCtor.prototype)` with a `constructor` back-reference. Node's
/// validation order: `ctor` non-null, `superCtor` non-null, then `superCtor.prototype` is an object
/// (each failure → an `ERR_INVALID_ARG_TYPE` TypeError with Node's exact message).
fn inherits(self: *Interpreter, args: []const Value) EvalError!Completion {
    const ctor_v: Value = if (args.len > 0) args[0] else .undefined;
    const super_v: Value = if (args.len > 1) args[1] else .undefined;
    if (ctor_v == .undefined or ctor_v == .null)
        return invalidArgType(self, "ctor", "Function", ctor_v);
    if (super_v == .undefined or super_v == .null)
        return invalidArgType(self, "superCtor", "Function", super_v);

    // Node requires `superCtor.prototype` to be an object (not that superCtor be a function).
    const super_proto_v: Value = if (super_v == .object) (super_v.object.get("prototype") orelse .undefined) else .undefined;
    if (super_proto_v != .object)
        return invalidArgType(self, "superCtor.prototype", "Object", super_proto_v);

    const ctor: *Object = if (ctor_v == .object) ctor_v.object else return invalidArgType(self, "ctor", "Function", ctor_v);

    // ctor.super_ = superCtor (writable, configurable, NON-enumerable — Node uses an ordinary
    // assignment which yields a default data prop; the test asserts writable+configurable+!enumerable).
    try ctor.defineData("super_", super_v, true, false, true);

    // Modern Node: `Object.setPrototypeOf(ctor.prototype, superCtor.prototype)` — re-parent the
    // EXISTING `ctor.prototype` (so a class's own methods survive), rather than replacing it.
    const ctor_proto_v = ctor.get("prototype");
    if (ctor_proto_v) |cpv| if (cpv == .object) {
        cpv.object.prototype = super_proto_v.object;
    };

    return .{ .normal = .undefined };
}

/// Build + throw a Node `ERR_INVALID_ARG_TYPE` TypeError: `The "<name>" <kind> must be of type
/// <expected>. Received <typeOf(v)>` where `kind` is "property" for a dotted name, else "argument",
/// and `<expected>` is lower-cased ("Function" → "function").
fn invalidArgType(self: *Interpreter, name: []const u8, expected: []const u8, v: Value) EvalError!Completion {
    const arena = self.arena;
    const kind = if (std.mem.indexOfScalar(u8, name, '.') != null) "property" else "argument";
    const exp_lower = std.ascii.allocLowerString(arena, expected) catch return error.OutOfMemory;
    const msg = std.fmt.allocPrint(
        arena,
        "The \"{s}\" {s} must be of type {s}. Received {s}",
        .{ name, kind, exp_lower, argTypeName(v) },
    ) catch return error.OutOfMemory;
    const err = try Object.create(arena, self.errorProto("TypeError"));
    err.error_data = true;
    try err.set("name", .{ .string = "TypeError" });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = "ERR_INVALID_ARG_TYPE" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// The token Node's `ERR_INVALID_ARG_TYPE` prints for a received value's type (the simple cases the
/// host tests exercise: `null`, `undefined`, and the primitive `typeof`s).
fn argTypeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .undefined => "undefined",
        .boolean => "type boolean",
        .number => "type number",
        .string => "type string",
        .symbol => "type symbol",
        .object => "an instance of Object",
        else => "an instance of Object",
    };
}

// ── deprecate ───────────────────────────────────────────────────────────────────

/// `util.deprecate(fn, msg)` → a wrapper that (best-effort) warns once then forwards to the original.
fn deprecate(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const fn_v: Value = if (args.len > 0) args[0] else .undefined;
    if (fn_v != .object or fn_v.object.kind != .function) {
        // Node returns the value unchanged for a non-function.
        return .{ .normal = fn_v };
    }
    const msg_v: Value = if (args.len > 1) args[1] else .{ .string = "" };
    const wrapper = try Object.createNative(arena, .util_method, "");
    wrapper.prototype = self.functionProto();
    _ = wrapper.properties.orderedRemove("prototype");
    try wrapper.defineData("%deprecated_fn%", fn_v, false, false, true);
    try wrapper.defineData("%deprecated_msg%", msg_v, false, false, true);
    try wrapper.defineData("%deprecated_warned%", .{ .boolean = false }, true, false, true);
    return .{ .normal = .{ .object = wrapper } };
}

fn deprecateWrapper(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const fn_v = func.get("%deprecated_fn%") orelse return .{ .normal = .undefined };
    if (fn_v != .object) return .{ .normal = .undefined };
    // Warn once (best-effort; flip the flag — no host stderr dependency).
    const warned = func.get("%deprecated_warned%");
    if (warned == null or warned.? != .boolean or !warned.?.boolean) {
        try func.defineData("%deprecated_warned%", .{ .boolean = true }, true, false, true);
    }
    return self.callFunction(fn_v.object, args, .undefined);
}

// ── types predicates ────────────────────────────────────────────────────────────

fn typesPredicate(name: []const u8, args: []const Value) EvalError!Completion {
    const v: Value = if (args.len > 0) args[0] else .undefined;
    const obj: ?*Object = if (v == .object) v.object else null;
    const r: bool = blk: {
        const o = obj orelse break :blk false;
        if (eql(u8, name, "isDate")) break :blk o.date_value != null;
        if (eql(u8, name, "isRegExp")) break :blk o.regexp != null;
        if (eql(u8, name, "isNativeError")) break :blk o.error_data;
        if (eql(u8, name, "isPromise")) break :blk o.promise != null;
        if (eql(u8, name, "isArrayBuffer")) break :blk o.kind == .array_buffer;
        if (eql(u8, name, "isTypedArray")) break :blk o.typed_array != null;
        if (eql(u8, name, "isMap")) break :blk o.collection != null and o.collection.?.kind == .map;
        if (eql(u8, name, "isSet")) break :blk o.collection != null and o.collection.?.kind == .set;
        if (eql(u8, name, "isWeakMap")) break :blk o.collection != null and o.collection.?.kind == .weakmap;
        if (eql(u8, name, "isWeakSet")) break :blk o.collection != null and o.collection.?.kind == .weakset;
        if (eql(u8, name, "isDataView")) break :blk o.kind == .data_view;
        if (eql(u8, name, "isProxy")) break :blk o.proxy != null;
        if (eql(u8, name, "isGeneratorObject")) break :blk o.generator != null and !o.generator.?.is_async;
        if (eql(u8, name, "isAsyncGeneratorObject")) break :blk o.async_generator != null;
        // SharedArrayBuffer is not distinctly modelled — treat as a plain ArrayBuffer (never shared).
        if (eql(u8, name, "isSharedArrayBuffer")) break :blk false;
        if (eql(u8, name, "isAnyArrayBuffer")) break :blk o.kind == .array_buffer;
        // Map/Set iterators are not branded distinctly in this engine.
        if (eql(u8, name, "isMapIterator")) break :blk false;
        if (eql(u8, name, "isSetIterator")) break :blk false;
        if (eql(u8, name, "isGeneratorFunction"))
            break :blk o.kind == .function and o.call != null and o.call.?.is_generator and !o.call.?.is_async;
        if (eql(u8, name, "isAsyncFunction"))
            break :blk o.kind == .function and o.call != null and o.call.?.is_async;
        // Boxed primitives: `new Number/String/Boolean/Symbol(x)` carry `primitive`.
        if (eql(u8, name, "isBooleanObject")) break :blk o.primitive != null and o.primitive.? == .boolean;
        if (eql(u8, name, "isNumberObject")) break :blk o.primitive != null and o.primitive.? == .number;
        if (eql(u8, name, "isStringObject")) break :blk o.primitive != null and o.primitive.? == .string;
        if (eql(u8, name, "isSymbolObject")) break :blk o.primitive != null and o.primitive.? == .symbol;
        if (eql(u8, name, "isBigIntObject")) break :blk o.primitive != null and o.primitive.? == .bigint;
        if (eql(u8, name, "isBoxedPrimitive")) break :blk o.primitive != null;
        break :blk false;
    };
    return .{ .normal = .{ .boolean = r } };
}

// ── isDeepStrictEqual ────────────────────────────────────────────────────────────

/// A pragmatic structural deep-equality (SameValue on primitives, recursive on own enumerable
/// string keys / array elements). Sufficient for the common smoke path; not a full SameValueZero +
/// Map/Set/typed-array walk.
fn deepEqual(self: *Interpreter, a: Value, b: Value) EvalError!bool {
    if (a == .object and b == .object) {
        const oa = a.object;
        const ob = b.object;
        if (oa == ob) return true;
        if (oa.kind == .array and ob.kind == .array) {
            const la = oa.arrayLen();
            if (la != ob.arrayLen()) return false;
            var i: usize = 0;
            while (i < la) : (i += 1) {
                if (!try deepEqual(self, oa.arrayGet(i), ob.arrayGet(i))) return false;
            }
            return true;
        }
        // Plain objects: same set of own enumerable string keys + equal values.
        if (!try sameKeys(self, oa, ob)) return false;
        if (!try sameKeys(self, ob, oa)) return false;
        return true;
    }
    return sameValue(a, b);
}

fn sameKeys(self: *Interpreter, oa: *Object, ob: *Object) EvalError!bool {
    var it = oa.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable or pv.payload != .data) continue;
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '%') continue;
        const bv = ob.get(key) orelse return false;
        if (!try deepEqual(self, pv.payload.data, bv)) return false;
    }
    return true;
}

fn sameValue(a: Value, b: Value) bool {
    return switch (a) {
        .undefined => b == .undefined,
        .null => b == .null,
        .boolean => b == .boolean and a.boolean == b.boolean,
        .number => b == .number and (a.number == b.number or (std.math.isNan(a.number) and std.math.isNan(b.number))),
        .string => b == .string and std.mem.eql(u8, a.string, b.string),
        .object => b == .object and a.object == b.object,
        else => std.meta.eql(a, b),
    };
}
