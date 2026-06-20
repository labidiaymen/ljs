//! HOST runtime (Node axis, spec 104 Unit A — NOT ECMA-262): Node's `assert` core module.
//! Requireable as `require('assert')`, `require('node:assert')`, and `require('assert/strict')`.
//! Host-only — never on the Test262 engine surface (host core modules are not requireable there).
//!
//! The default export is the CALLABLE `assert(value[, message])` (the truthy `ok` check) that ALSO
//! carries all the assertion methods as own properties, plus `assert.strict` (a namespace where the
//! loose methods alias the strict ones) and `assert.AssertionError` (the error class, an
//! `instanceof Error` whose instances carry `name="AssertionError"`, `code="ERR_ASSERTION"`, and the
//! `actual`/`expected`/`operator` own props).
//!
//! Mechanics mirror the other host modules: the exports are a plain object of `.assert_method`
//! natives (built once per run, cached by `host_require`). Dispatch is by `func.native_name`. The
//! `.strict` namespace's loose methods are distinct natives whose dispatch name is the strict
//! implementation (so `assert.strict.equal` runs `strictEqual`).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const ops = @import("abstract_ops.zig");
const async_mod = @import("interp_async.zig");

const eql = std.mem.eql;

// ── build the module ─────────────────────────────────────────────────────────────

/// Build the `assert` module exports object: the callable `assert` fn (a `.assert_method` native
/// named "ok") with all the methods as own props, `assert.strict`, and `assert.AssertionError`.
pub fn build(self: *Interpreter) EvalError!*Object {
    return buildNamespace(self, false);
}

/// `require('assert/strict')` → the strict namespace (same as `require('assert').strict`).
pub fn buildStrict(self: *Interpreter) EvalError!*Object {
    return buildNamespace(self, true);
}

/// Build an assert namespace. `strict` mode aliases the loose comparison names onto the strict
/// implementations.
fn buildNamespace(self: *Interpreter, strict: bool) EvalError!*Object {
    // The default export IS the callable `assert(value[, message])` — a `.assert_method` native named
    // "ok" (the truthy check); it also carries the methods as own props.
    const root = try makeMethod(self, "ok");

    // Comparison methods. In strict mode the loose names route to the strict implementations.
    try attach(self, root, "ok", "ok");
    try attach(self, root, "equal", if (strict) "strictEqual" else "equal");
    try attach(self, root, "notEqual", if (strict) "notStrictEqual" else "notEqual");
    try attach(self, root, "deepEqual", if (strict) "deepStrictEqual" else "deepEqual");
    try attach(self, root, "notDeepEqual", if (strict) "notDeepStrictEqual" else "notDeepEqual");
    try attach(self, root, "strictEqual", "strictEqual");
    try attach(self, root, "notStrictEqual", "notStrictEqual");
    try attach(self, root, "deepStrictEqual", "deepStrictEqual");
    try attach(self, root, "notDeepStrictEqual", "notDeepStrictEqual");
    try attach(self, root, "throws", "throws");
    try attach(self, root, "doesNotThrow", "doesNotThrow");
    try attach(self, root, "rejects", "rejects");
    try attach(self, root, "doesNotReject", "doesNotReject");
    try attach(self, root, "match", "match");
    try attach(self, root, "doesNotMatch", "doesNotMatch");
    try attach(self, root, "ifError", "ifError");
    try attach(self, root, "fail", "fail");

    // assert.AssertionError — the error class.
    const ae_ctor = try makeAssertionErrorClass(self);
    try root.defineData("AssertionError", .{ .object = ae_ctor }, true, false, true);

    // assert.strict — the strict namespace. On the loose export it builds the strict one; the strict
    // namespace's own `.strict` points back at itself (avoiding infinite recursion).
    if (!strict) {
        const strict_ns = try buildNamespace(self, true);
        try root.defineData("strict", .{ .object = strict_ns }, true, false, true);
    } else {
        try root.defineData("strict", .{ .object = root }, true, false, true);
    }

    return root;
}

/// Create a bare `.assert_method` native function object named `name`.
fn makeMethod(self: *Interpreter, name: []const u8) EvalError!*Object {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .assert_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    return fn_obj;
}

/// Define `key` on `target` as a `.assert_method` native whose dispatch name is `impl` (so a loose
/// alias in strict mode can route to the strict implementation).
fn attach(self: *Interpreter, target: *Object, key: []const u8, impl: []const u8) EvalError!void {
    const fn_obj = try makeMethod(self, impl);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

// ── AssertionError class ─────────────────────────────────────────────────────────

/// Build `assert.AssertionError` — a constructor (`.assert_method` named "AssertionError") whose
/// `.prototype` is [[Prototype]]-linked to %Error.prototype% (so `e instanceof Error` holds), with a
/// `name` of "AssertionError".
fn makeAssertionErrorClass(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const proto = try Object.create(arena, self.errorProto("Error"));
    try proto.defineData("name", .{ .string = "AssertionError" }, true, false, true);

    const ctor = try Object.createNative(arena, .assert_method, "AssertionError");
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = "AssertionError" }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);
    return ctor;
}

/// The %AssertionError.prototype% for new instances — resolved off the cached `assert` module's
/// `AssertionError.prototype` (so `instanceof assert.AssertionError` holds). Falls back to
/// %Error.prototype% if the module is not yet cached.
fn assertionErrorProto(self: *Interpreter) ?*Object {
    if (self.core_module_cache.get("assert")) |exports| {
        if (exports == .object) {
            if (exports.object.get("AssertionError")) |ae| {
                if (ae == .object) {
                    if (ae.object.get("prototype")) |p| {
                        if (p == .object) return p.object;
                    }
                }
            }
        }
    }
    return self.errorProto("Error");
}

/// Build an AssertionError Value and return it as a `.throw` completion. Sets `name`,
/// `code="ERR_ASSERTION"`, and the `actual`/`expected`/`operator` own props; proto-linked to
/// %AssertionError.prototype% (→ `instanceof Error` and `instanceof assert.AssertionError`).
fn fail(self: *Interpreter, message: []const u8, actual: Value, expected: Value, operator: []const u8) EvalError!Completion {
    const arena = self.arena;
    const err = try Object.create(arena, assertionErrorProto(self));
    err.error_data = true; // §20.5 [[ErrorData]] → Object.prototype.toString "Error" tag
    try err.defineData("name", .{ .string = "AssertionError" }, true, false, true);
    try err.defineData("message", .{ .string = message }, true, false, true);
    try err.defineData("code", .{ .string = "ERR_ASSERTION" }, true, false, true);
    try err.defineData("actual", actual, true, true, true);
    try err.defineData("expected", expected, true, true, true);
    try err.defineData("operator", .{ .string = operator }, true, true, true);
    try err.defineData("generatedMessage", .{ .boolean = true }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Resolve the optional trailing `message` arg of an assertion: a string → use it; an Error object →
/// re-throw it (Node lets you pass an Error as the message, which is thrown instead of an
/// AssertionError); else fall back to `default`. The Error case is signalled through `out_throw`.
fn resolveMessage(self: *Interpreter, msg_v: Value, default: []const u8, out_throw: *?Value) EvalError![]const u8 {
    out_throw.* = null;
    if (msg_v == .object and msg_v.object.error_data) {
        out_throw.* = msg_v;
        return default;
    }
    if (msg_v == .undefined or msg_v == .null) return default;
    if (msg_v == .string) return msg_v.string;
    const sc = try self.toStringValuePub(msg_v);
    if (sc.isAbrupt()) return default;
    return sc.normal.string;
}

// ── dispatch ─────────────────────────────────────────────────────────────────────

/// Dispatch a `.assert_method` native by `func.native_name`.
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    _ = this_val;
    const name = func.native_name;

    // A rejects/doesNotReject promise reaction native — settle the result promise.
    if (func.get("%rej_result%") != null) return rejectReaction(self, func, args);

    // The AssertionError constructor (reached via `new assert.AssertionError(...)`).
    if (eql(u8, name, "AssertionError")) return assertionErrorConstruct(self, args);

    const a0: Value = if (args.len > 0) args[0] else .undefined;
    const a1: Value = if (args.len > 1) args[1] else .undefined;
    const a2: Value = if (args.len > 2) args[2] else .undefined;

    if (eql(u8, name, "ok")) return assertOk(self, a0, a1);
    if (eql(u8, name, "fail")) return assertFail(self, a0);
    if (eql(u8, name, "ifError")) return ifError(self, a0);

    if (eql(u8, name, "equal")) return compare(self, a0, a1, a2, .equal, false);
    if (eql(u8, name, "notEqual")) return compare(self, a0, a1, a2, .equal, true);
    if (eql(u8, name, "strictEqual")) return compare(self, a0, a1, a2, .strict, false);
    if (eql(u8, name, "notStrictEqual")) return compare(self, a0, a1, a2, .strict, true);
    if (eql(u8, name, "deepEqual")) return compare(self, a0, a1, a2, .deep_loose, false);
    if (eql(u8, name, "notDeepEqual")) return compare(self, a0, a1, a2, .deep_loose, true);
    if (eql(u8, name, "deepStrictEqual")) return compare(self, a0, a1, a2, .deep_strict, false);
    if (eql(u8, name, "notDeepStrictEqual")) return compare(self, a0, a1, a2, .deep_strict, true);

    if (eql(u8, name, "match")) return matchRe(self, a0, a1, a2, false);
    if (eql(u8, name, "doesNotMatch")) return matchRe(self, a0, a1, a2, true);

    if (eql(u8, name, "throws")) return throws(self, args, false);
    if (eql(u8, name, "doesNotThrow")) return throws(self, args, true);
    if (eql(u8, name, "rejects")) return rejects(self, args, false);
    if (eql(u8, name, "doesNotReject")) return rejects(self, args, true);

    return .{ .normal = .undefined };
}

/// `new assert.AssertionError(options)` — build an AssertionError from an options object
/// (`{ message, actual, expected, operator }`). All fields optional. Returns the instance NORMALLY
/// (it's a constructor call, not a thrown failure).
fn assertionErrorConstruct(self: *Interpreter, args: []const Value) EvalError!Completion {
    const opts: Value = if (args.len > 0) args[0] else .undefined;
    var message: []const u8 = "Failed";
    var actual: Value = .undefined;
    var expected: Value = .undefined;
    var operator: []const u8 = "";
    if (opts == .object) {
        if (opts.object.get("message")) |m| if (m == .string) {
            message = m.string;
        };
        if (opts.object.get("actual")) |v| actual = v;
        if (opts.object.get("expected")) |v| expected = v;
        if (opts.object.get("operator")) |v| if (v == .string) {
            operator = v.string;
        };
    }
    const failc = try fail(self, message, actual, expected, operator);
    return .{ .normal = failc.throw };
}

// ── ok / fail / ifError ──────────────────────────────────────────────────────────

fn assertOk(self: *Interpreter, value: Value, msg_v: Value) EvalError!Completion {
    if (ops.toBoolean(value)) return .{ .normal = .undefined };
    var rethrow: ?Value = null;
    const msg = try resolveMessage(self, msg_v, "The expression evaluated to a falsy value:", &rethrow);
    if (rethrow) |e| return .{ .throw = e };
    return fail(self, msg, value, .{ .boolean = true }, "==");
}

fn assertFail(self: *Interpreter, msg_v: Value) EvalError!Completion {
    var rethrow: ?Value = null;
    const msg = try resolveMessage(self, msg_v, "Failed", &rethrow);
    if (rethrow) |e| return .{ .throw = e };
    return fail(self, msg, .undefined, .undefined, "fail");
}

/// `assert.ifError(value)` — throws `value` if it is not null/undefined. A caught Error keeps its
/// identity (re-thrown as-is); a truthy non-error value is wrapped in an AssertionError.
fn ifError(self: *Interpreter, value: Value) EvalError!Completion {
    if (value == .undefined or value == .null) return .{ .normal = .undefined };
    if (value == .object and value.object.error_data) return .{ .throw = value };
    const arena = self.arena;
    const s = try self.toStringValuePub(value);
    const vs = if (!s.isAbrupt() and s.normal == .string) s.normal.string else "";
    const msg = std.fmt.allocPrint(arena, "ifError got unwanted exception: {s}", .{vs}) catch return error.OutOfMemory;
    return fail(self, msg, value, .undefined, "ifError");
}

// ── comparisons ──────────────────────────────────────────────────────────────────

const CompareKind = enum { equal, strict, deep_loose, deep_strict };

fn compare(self: *Interpreter, actual: Value, expected: Value, msg_v: Value, kind: CompareKind, negate: bool) EvalError!Completion {
    const equal_result: bool = switch (kind) {
        .equal => ops.looseEquals(actual, expected),
        .strict => ops.sameValue(actual, expected),
        .deep_loose => try deepEqual(self, actual, expected, false),
        .deep_strict => try deepEqual(self, actual, expected, true),
    };
    const pass = if (negate) !equal_result else equal_result;
    if (pass) return .{ .normal = .undefined };

    const operator = switch (kind) {
        .equal => if (negate) "notEqual" else "equal",
        .strict => if (negate) "notStrictEqual" else "strictEqual",
        .deep_loose => if (negate) "notDeepEqual" else "deepEqual",
        .deep_strict => if (negate) "notDeepStrictEqual" else "deepStrictEqual",
    };

    var rethrow: ?Value = null;
    const default_msg = if (negate) "Expected values to be not equal" else "Expected values to be equal";
    const msg = try resolveMessage(self, msg_v, default_msg, &rethrow);
    if (rethrow) |e| return .{ .throw = e };
    return fail(self, msg, actual, expected, operator);
}

// ── deep equality (cycle-safe structural compare) ────────────────────────────────

const VisitedPair = struct { a: *Object, b: *Object };

/// `deepEqual` / `deepStrictEqual` structural compare. `strict` requires SameValueZero on leaf
/// primitives and type-tag/prototype equality; loose uses `==` on leaf primitives. Cycle-safe via a
/// visited-pair stack.
fn deepEqual(self: *Interpreter, a: Value, b: Value, strict: bool) EvalError!bool {
    var visited: std.ArrayListUnmanaged(VisitedPair) = .empty;
    return deepEqualRec(self, a, b, strict, &visited);
}

fn deepEqualRec(self: *Interpreter, a: Value, b: Value, strict: bool, visited: *std.ArrayListUnmanaged(VisitedPair)) EvalError!bool {
    if (a == .object and b == .object) return deepEqualObjects(self, a.object, b.object, strict, visited);
    if (strict) return ops.sameValueZero(a, b); // NaN===NaN; +0/-0 equal (Node's deepStrictEqual leaves)
    if (a == .object or b == .object) return false; // an object never loosely-equals a bare primitive here
    return ops.looseEquals(a, b);
}

fn deepEqualObjects(self: *Interpreter, a: *Object, b: *Object, strict: bool, visited: *std.ArrayListUnmanaged(VisitedPair)) EvalError!bool {
    if (a == b) return true;

    // Cycle guard: this exact pair already on the comparison stack → treat as equal.
    for (visited.items) |vp| if (vp.a == a and vp.b == b) return true;
    visited.append(self.arena, .{ .a = a, .b = b }) catch return error.OutOfMemory;
    defer _ = visited.pop();

    // In strict mode the [[Prototype]] must match (Node's deepStrictEqual compares prototypes).
    if (strict and a.prototype != b.prototype) return false;

    // Dates → equal time value.
    if (a.date_value != null or b.date_value != null) {
        if (a.date_value == null or b.date_value == null) return false;
        const ta = a.date_value.?;
        const tb = b.date_value.?;
        if (std.math.isNan(ta) and std.math.isNan(tb)) return true;
        return ta == tb;
    }

    // RegExp → same source + flags (then fall through to compare own props too).
    if (a.regexp != null or b.regexp != null) {
        if (a.regexp == null or b.regexp == null) return false;
        if (!eql(u8, a.regexp.?.source, b.regexp.?.source)) return false;
        if (!eql(u8, a.regexp.?.flags, b.regexp.?.flags)) return false;
    }

    // ArrayBuffer → equal byte content.
    if (a.array_buffer != null or b.array_buffer != null) {
        if (a.array_buffer == null or b.array_buffer == null) return false;
        return std.mem.eql(u8, a.array_buffer.?.bytes, b.array_buffer.?.bytes);
    }

    // TypedArray → same element type (strict) + equal viewed bytes.
    if (a.typed_array != null or b.typed_array != null) {
        if (a.typed_array == null or b.typed_array == null) return false;
        const taa = a.typed_array.?;
        const tab = b.typed_array.?;
        if (strict and taa.elem != tab.elem) return false;
        const ba = viewedBytes(taa) orelse return false;
        const bb = viewedBytes(tab) orelse return false;
        return std.mem.eql(u8, ba, bb);
    }

    // Map / Set.
    if (a.collection != null or b.collection != null) {
        if (a.collection == null or b.collection == null) return false;
        return collectionsEqual(self, a.collection.?, b.collection.?, strict, visited);
    }

    // Arrays → same length + element-wise deep compare (then fall through to extra own props).
    if (a.kind == .array or b.kind == .array) {
        if (a.kind != .array or b.kind != .array) return false;
        const la = a.arrayLen();
        if (la != b.arrayLen()) return false;
        var i: usize = 0;
        while (i < la) : (i += 1) {
            if (!try deepEqualRec(self, a.arrayGet(i), b.arrayGet(i), strict, visited)) return false;
        }
    }

    // Plain objects (and the residual own props of the exotics above): same set of own enumerable
    // string keys with deep-equal values.
    if (!try sameOwnKeys(self, a, b, strict, visited)) return false;
    if (!try sameOwnKeys(self, b, a, strict, visited)) return false;
    return true;
}

/// The `array_length`-element viewed byte slice of a TypedArray (bpe-scaled), or null if detached /
/// out of range.
fn viewedBytes(ta: object_mod.TypedArrayData) ?[]const u8 {
    const ab = ta.buffer.array_buffer orelse return null;
    if (ab.detached) return null;
    const start = ta.byte_offset;
    const end = start + ta.array_length * ta.elem.bytesPerElement();
    if (end > ab.bytes.len) return null;
    return ab.bytes[start..end];
}

/// Compare two collections (Map/Set) of the same kind: equal size and every present entry of `a` has
/// a deep-equal, not-yet-matched counterpart in `b`. For a Set the values ARE the keys; for a Map
/// both key and value must match.
fn collectionsEqual(self: *Interpreter, ca: *object_mod.Collection, cb: *object_mod.Collection, strict: bool, visited: *std.ArrayListUnmanaged(VisitedPair)) EvalError!bool {
    if (ca.kind != cb.kind) return false;
    if (ca.size != cb.size) return false;
    const is_map = ca.kind == .map or ca.kind == .weakmap;

    var matched: std.ArrayListUnmanaged(bool) = .empty;
    matched.appendNTimes(self.arena, false, cb.entries.items.len) catch return error.OutOfMemory;

    for (ca.entries.items) |ea| {
        if (!ea.present) continue;
        var found = false;
        for (cb.entries.items, 0..) |eb, j| {
            if (!eb.present or matched.items[j]) continue;
            if (!try deepEqualRec(self, ea.key, eb.key, strict, visited)) continue;
            if (is_map and !try deepEqualRec(self, ea.value, eb.value, strict, visited)) continue;
            matched.items[j] = true;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

/// Every own enumerable string-keyed data property of `oa` has a deep-equal counterpart on `ob`.
/// Skips hidden host-state keys (leading `%`) and (for arrays) the numeric index props already
/// compared element-wise. Symbol keys are out of scope (never on the conformance surface).
fn sameOwnKeys(self: *Interpreter, oa: *Object, ob: *Object, strict: bool, visited: *std.ArrayListUnmanaged(VisitedPair)) EvalError!bool {
    var it = oa.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable) continue;
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '%') continue;
        if (oa.kind == .array and ops.parseIndex(key) != null) continue;
        const bv_pv = ob.properties.getPtr(key) orelse return false;
        if (!bv_pv.enumerable) return false;
        const av: Value = switch (pv.payload) {
            .data => pv.payload.data,
            .accessor => continue, // accessors are not structurally compared
        };
        const bv: Value = switch (bv_pv.payload) {
            .data => bv_pv.payload.data,
            .accessor => return false,
        };
        if (!try deepEqualRec(self, av, bv, strict, visited)) return false;
    }
    return true;
}

// ── match / doesNotMatch ─────────────────────────────────────────────────────────

/// `assert.match(string, regexp[, message])` — assert `regexp.test(string)` (doesNotMatch negates).
fn matchRe(self: *Interpreter, str_v: Value, re_v: Value, msg_v: Value, negate: bool) EvalError!Completion {
    if (str_v != .string) return self.throwError("TypeError", "The \"string\" argument must be of type string");
    if (re_v != .object or re_v.object.regexp == null) {
        return self.throwError("TypeError", "The \"regexp\" argument must be an instance of RegExp");
    }
    const tested = try regexpTest(self, re_v.object, str_v.string);
    if (tested.isAbrupt()) return tested;
    const matched = tested.normal == .boolean and tested.normal.boolean;
    const pass = if (negate) !matched else matched;
    if (pass) return .{ .normal = .undefined };

    var rethrow: ?Value = null;
    const default_msg = if (negate) "The input was expected to not match the regular expression" else "The input did not match the regular expression";
    const msg = try resolveMessage(self, msg_v, default_msg, &rethrow);
    if (rethrow) |e| return .{ .throw = e };
    return fail(self, msg, str_v, re_v, if (negate) "doesNotMatch" else "match");
}

/// Invoke `regexp.test(string)` through the engine (so the real matcher runs).
fn regexpTest(self: *Interpreter, re: *Object, s: []const u8) EvalError!Completion {
    const test_v = try self.getProperty(.{ .object = re }, "test");
    if (test_v.isAbrupt()) return test_v;
    if (test_v.normal != .object) return self.throwError("TypeError", "regexp.test is not a function");
    return self.callFunction(test_v.normal.object, &.{.{ .string = s }}, .{ .object = re });
}

// ── throws / doesNotThrow ────────────────────────────────────────────────────────

/// `assert.throws(fn[, expected[, message]])` — call `fn()`; assert it threw, and (if `expected`)
/// that the thrown error matches. `doesNotThrow` (negate) asserts it did NOT throw.
fn throws(self: *Interpreter, args: []const Value, negate: bool) EvalError!Completion {
    const fn_v: Value = if (args.len > 0) args[0] else .undefined;
    if (fn_v != .object or fn_v.object.kind != .function) {
        return self.throwError("TypeError", "The \"fn\" argument must be of type function");
    }
    var expected: Value = if (args.len > 1) args[1] else .undefined;
    var msg_v: Value = if (args.len > 2) args[2] else .undefined;
    if (expected == .string) {
        // A string in the `expected` slot is the message (Node assert.throws semantics).
        msg_v = expected;
        expected = .undefined;
    }

    const c = try self.callFunction(fn_v.object, &.{}, .undefined);

    if (c == .throw) {
        if (negate) {
            // doesNotThrow but it threw → fail.
            var rethrow: ?Value = null;
            const msg = try resolveMessage(self, msg_v, "Got unwanted exception.", &rethrow);
            if (rethrow) |e| return .{ .throw = e };
            return fail(self, msg, c.throw, .undefined, "doesNotThrow");
        }
        // throws: verify the thrown error matches `expected` (if provided).
        if (expected != .undefined and expected != .null) {
            const ok = try errorMatches(self, c.throw, expected);
            if (ok.isAbrupt()) return ok;
            if (ok.normal == .boolean and !ok.normal.boolean) {
                // Did not match → re-throw the original error (Node propagates it).
                return .{ .throw = c.throw };
            }
        }
        return .{ .normal = .undefined }; // matched (or no matcher) → pass, SWALLOW the throw
    }

    // No throw.
    if (negate) return .{ .normal = .undefined }; // doesNotThrow + no throw → pass
    var rethrow: ?Value = null;
    const msg = try resolveMessage(self, msg_v, "Missing expected exception.", &rethrow);
    if (rethrow) |e| return .{ .throw = e };
    return fail(self, msg, .undefined, expected, "throws");
}

/// Does `err` match `expected`? A constructor → `err instanceof expected`; a RegExp → its `message`
/// matches; a plain object → property-subset (deepStrictEqual) match; a function → a predicate
/// (truthy return passes).
fn errorMatches(self: *Interpreter, err: Value, expected: Value) EvalError!Completion {
    if (expected != .object) return .{ .normal = .{ .boolean = false } };
    const eo = expected.object;

    // A RegExp matcher → test against the error's message.
    if (eo.regexp != null) {
        const msg = try errorMessageString(self, err);
        return regexpTest(self, eo, msg);
    }

    // A function: either a constructor (instanceof) or a validation predicate.
    if (eo.kind == .function) {
        const inst = try self.ordinaryHasInstance(expected, err);
        if (inst.isAbrupt()) return inst;
        if (inst.normal == .boolean and inst.normal.boolean) return .{ .normal = .{ .boolean = true } };
        // Not an instance → treat as a predicate: expected(err) truthy ⇒ pass.
        const r = try self.callFunction(eo, &.{err}, .undefined);
        if (r.isAbrupt()) return r;
        return .{ .normal = .{ .boolean = ops.toBoolean(r.normal) } };
    }

    // A plain object matcher → every own enumerable prop must deep-equal the error's prop.
    if (err != .object) return .{ .normal = .{ .boolean = false } };
    var it = eo.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable or pv.payload != .data) continue;
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '%') continue;
        const want = pv.payload.data;
        const got_c = try self.getProperty(err, key);
        if (got_c.isAbrupt()) return got_c;
        // A RegExp-valued property (e.g. `{ message: /.../ }`) is tested against the actual value's
        // string form (Node's assert.throws semantics), not deep-equaled.
        if (want == .object and want.object.regexp != null) {
            const sc = try self.toStringValuePub(got_c.normal);
            if (sc.isAbrupt()) return sc;
            const tc = try regexpTest(self, want.object, sc.normal.string);
            if (tc.isAbrupt()) return tc;
            if (!(tc.normal == .boolean and tc.normal.boolean)) return .{ .normal = .{ .boolean = false } };
            continue;
        }
        if (!try deepEqual(self, got_c.normal, want, true)) return .{ .normal = .{ .boolean = false } };
    }
    return .{ .normal = .{ .boolean = true } };
}

/// The `message` of a thrown error (string), or its String() for a non-error throw.
fn errorMessageString(self: *Interpreter, err: Value) EvalError![]const u8 {
    if (err == .object) {
        if (err.object.get("message")) |m| if (m == .string) return m.string;
    }
    const sc = try self.toStringValuePub(err);
    if (!sc.isAbrupt() and sc.normal == .string) return sc.normal.string;
    return "";
}

// ── rejects / doesNotReject (promise-returning) ──────────────────────────────────

/// `assert.rejects(fnOrPromise[, expected[, message]])` — returns a Promise that fulfills if the
/// awaited value rejected (and matched `expected`), else rejects with an AssertionError.
/// `doesNotReject` (negate) is the inverse.
fn rejects(self: *Interpreter, args: []const Value, negate: bool) EvalError!Completion {
    const arg0: Value = if (args.len > 0) args[0] else .undefined;
    var expected: Value = if (args.len > 1) args[1] else .undefined;
    var msg_v: Value = if (args.len > 2) args[2] else .undefined;
    if (expected == .string) {
        msg_v = expected;
        expected = .undefined;
    }

    const result = try async_mod.newPromise(self);

    // Obtain the promise/thenable to observe: a function → call it (a sync throw is a rejection for
    // `rejects`); otherwise the value itself.
    var observed: Value = arg0;
    if (arg0 == .object and arg0.object.kind == .function) {
        const c = try self.callFunction(arg0.object, &.{}, .undefined);
        if (c == .throw) {
            try settleRejects(self, result, true, c.throw, expected, msg_v, negate);
            return .{ .normal = .{ .object = result } };
        }
        observed = c.normal;
    }

    // A non-promise input → reject the returned promise with a TypeError.
    if (observed != .object or observed.object.promise == null) {
        const te = try self.throwError("TypeError", "The \"promiseFn\" argument must be of type function or an instance of Promise");
        try async_mod.rejectPromise(self, result, te.throw);
        return .{ .normal = .{ .object = result } };
    }

    try attachRejectReactions(self, observed.object, result, expected, msg_v, negate);
    return .{ .normal = .{ .object = result } };
}

/// Settle `result` for a directly-known outcome (`rejected` = whether the observed value rejected).
fn settleRejects(self: *Interpreter, result: *Object, rejected: bool, reason: Value, expected: Value, msg_v: Value, negate: bool) EvalError!void {
    if (!negate) {
        // rejects: a rejection is expected.
        if (rejected) {
            if (expected != .undefined and expected != .null) {
                const ok = try errorMatches(self, reason, expected);
                if (!ok.isAbrupt() and ok.normal == .boolean and !ok.normal.boolean) {
                    try async_mod.rejectPromise(self, result, reason);
                    return;
                }
            }
            try async_mod.resolvePromise(self, result, .undefined);
        } else {
            try async_mod.rejectPromise(self, result, try failValue(self, msg_v, "Missing expected rejection.", "rejects"));
        }
    } else {
        // doesNotReject: a rejection is unwanted.
        if (rejected) {
            try async_mod.rejectPromise(self, result, try failValue(self, msg_v, "Got unwanted rejection.", "doesNotReject"));
        } else {
            try async_mod.resolvePromise(self, result, .undefined);
        }
    }
}

/// Build an AssertionError as a Value (for rejecting a promise). Honors an Error/string message arg.
fn failValue(self: *Interpreter, msg_v: Value, default: []const u8, operator: []const u8) EvalError!Value {
    var rethrow: ?Value = null;
    const msg = try resolveMessage(self, msg_v, default, &rethrow);
    if (rethrow) |e| return e;
    const fc = try fail(self, msg, .undefined, .undefined, operator);
    return fc.throw;
}

/// Register fulfill/reject reactions on `observed` that settle `result` per the rejects semantics.
fn attachRejectReactions(self: *Interpreter, observed: *Object, result: *Object, expected: Value, msg_v: Value, negate: bool) EvalError!void {
    const arena = self.arena;
    const pd = observed.promise.?;

    const onFulfilled = try makeReactionNative(self, result, expected, msg_v, negate, false);
    const onRejected = try makeReactionNative(self, result, expected, msg_v, negate, true);

    switch (pd.state) {
        .fulfilled => _ = try self.callFunction(onFulfilled, &.{pd.result}, .undefined),
        .rejected => _ = try self.callFunction(onRejected, &.{pd.result}, .undefined),
        .pending => {
            pd.fulfill_reactions.append(arena, .{ .kind = .fulfill, .handler = onFulfilled, .capability = null }) catch return error.OutOfMemory;
            pd.reject_reactions.append(arena, .{ .kind = .reject, .handler = onRejected, .capability = null }) catch return error.OutOfMemory;
        },
    }
}

/// Build a `.assert_method` reaction native carrying the settle state (`%rej_*%` hidden props).
fn makeReactionNative(self: *Interpreter, result: *Object, expected: Value, msg_v: Value, negate: bool, is_reject: bool) EvalError!*Object {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .assert_method, "%reject_reaction%");
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%rej_result%", .{ .object = result }, false, false, true);
    try fn_obj.defineData("%rej_expected%", expected, false, false, true);
    try fn_obj.defineData("%rej_msg%", msg_v, false, false, true);
    try fn_obj.defineData("%rej_negate%", .{ .boolean = negate }, false, false, true);
    try fn_obj.defineData("%rej_is_reject%", .{ .boolean = is_reject }, false, false, true);
    return fn_obj;
}

/// The reaction native body: read the captured state and settle the result promise. Called by the
/// Job queue with the settlement value as args[0] (a fulfillment value for the fulfill reaction, a
/// rejection reason for the reject reaction).
fn rejectReaction(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const result_v = func.get("%rej_result%").?;
    if (result_v != .object) return .{ .normal = .undefined };
    const result = result_v.object;
    const expected = func.get("%rej_expected%") orelse .undefined;
    const msg_v = func.get("%rej_msg%") orelse .undefined;
    const negate = blk: {
        const v = func.get("%rej_negate%") orelse break :blk false;
        break :blk v == .boolean and v.boolean;
    };
    const is_reject = blk: {
        const v = func.get("%rej_is_reject%") orelse break :blk false;
        break :blk v == .boolean and v.boolean;
    };
    const reason: Value = if (args.len > 0) args[0] else .undefined;
    // This reaction firing on the REJECT branch means the observed promise rejected; the FULFILL
    // branch means it fulfilled (i.e. it did NOT reject).
    try settleRejects(self, result, is_reject, reason, expected, msg_v, negate);
    return .{ .normal = .undefined };
}
