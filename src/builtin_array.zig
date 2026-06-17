//! §23.1.3 `Array.prototype` methods + `Array.isArray` + the `Array.from`/`Array.of` statics. Native
//! built-ins dispatched from the interpreter's `callNative` (`array_method` / `array_static`); `this`
//! is the receiver array. Lives in its own file so the interpreter stays the evaluator.
//!
//! The M-subset operates on the Array exotic (`this.object.kind == .array`): the dense/sparse store is
//! read through `Object.arrayGet`/`arrayLen` (length-aware, hole-aware) and written through
//! `arraySet`/`arrayPush` so methods never materialize a huge sparse array. Holes are visited or
//! skipped per the per-method spec (forEach/map/filter/some/every/reduce skip; find*/fill/includes
//! visit).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

const num = struct {
    fn v(n: usize) Value {
        return .{ .number = @floatFromInt(n) };
    }
};

pub fn call(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    if (eql(u8, name, "isArray")) {
        const v: Value = if (args.len > 0) args[0] else .undefined;
        return .{ .normal = .{ .boolean = v == .object and v.object.kind == .array } };
    }
    if (this_val != .object or this_val.object.kind != .array) {
        return it.throwError("TypeError", "Array.prototype method called on non-array");
    }
    const arr = this_val.object;
    const len = arr.arrayLen();

    // ── mutation: stack / queue ──────────────────────────────────────────────────────────────────
    if (eql(u8, name, "push")) { // §23.1.3.23 — each Set(O, len+k, E, true); frozen/non-ext → TypeError
        var k: usize = len;
        for (args) |a| {
            if (try setT(it, arr, k, a)) |c| return c;
            k += 1;
        }
        if (args.len > 0) if (try setLenT(it, arr, k)) |c| return c;
        return .{ .normal = num.v(arr.arrayLen()) };
    }
    if (eql(u8, name, "pop")) { // §23.1.3.22 — DeletePropertyOrThrow(last) + Set length (Throw=true)
        if (len == 0) {
            if (try setLenT(it, arr, 0)) |c| return c;
            return .{ .normal = .undefined };
        }
        const last = arr.arrayGet(len - 1);
        if (try delT(it, arr, len - 1)) |c| return c;
        if (try setLenT(it, arr, len - 1)) |c| return c;
        return .{ .normal = last };
    }
    if (eql(u8, name, "shift")) { // §23.1.3.27
        if (len == 0) {
            if (try setLenT(it, arr, 0)) |c| return c;
            return .{ .normal = .undefined };
        }
        const first = arr.arrayGet(0);
        var i: usize = 1;
        while (i < len) : (i += 1) {
            if (arr.arrayHas(i)) {
                if (try setT(it, arr, i - 1, arr.arrayGet(i))) |c| return c;
            } else if (try delT(it, arr, i - 1)) |c| return c;
        }
        if (try delT(it, arr, len - 1)) |c| return c;
        if (try setLenT(it, arr, len - 1)) |c| return c;
        return .{ .normal = first };
    }
    if (eql(u8, name, "unshift")) { // §23.1.3.33
        const argc = args.len;
        if (argc > 0) {
            // Shift existing elements up by argc, from the top down (Set/Delete with Throw=true).
            var i: usize = len;
            while (i > 0) : (i -= 1) {
                if (arr.arrayHas(i - 1)) {
                    if (try setT(it, arr, i - 1 + argc, arr.arrayGet(i - 1))) |c| return c;
                } else if (try delT(it, arr, i - 1 + argc)) |c| return c;
            }
            for (args, 0..) |a, j| if (try setT(it, arr, j, a)) |c| return c;
        }
        // §23.1.3.33 step 5: Set(O, "length", len + argCount, true) is performed UNCONDITIONALLY — so
        // `[].unshift()` on a non-writable-length / frozen array still throws.
        if (try setLenT(it, arr, len + argc)) |c| return c;
        return .{ .normal = num.v(len + argc) };
    }

    // ── search ───────────────────────────────────────────────────────────────────────────────────
    if (eql(u8, name, "indexOf")) { // §23.1.3.14 (strict equality, skips holes)
        if (len == 0) return .{ .normal = .{ .number = -1 } }; // §step 4: before ToInteger(fromIndex)
        const target: Value = if (args.len > 0) args[0] else .undefined;
        var i: usize = if (args.len > 1) switch (try fromIndexStart(it, args[1], len)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        } else 0;
        while (i < len) : (i += 1) {
            if (arr.arrayHas(i) and ops.strictEquals(arr.arrayGet(i), target)) return .{ .normal = num.v(i) };
        }
        return .{ .normal = .{ .number = -1 } };
    }
    if (eql(u8, name, "lastIndexOf")) { // §23.1.3.19
        const target: Value = if (args.len > 0) args[0] else .undefined;
        if (len == 0) return .{ .normal = .{ .number = -1 } };
        var i: isize = if (args.len > 1) switch (try fromIndexLast(it, args[1], len)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        } else @as(isize, @intCast(len)) - 1;
        while (i >= 0) : (i -= 1) {
            const u: usize = @intCast(i);
            if (arr.arrayHas(u) and ops.strictEquals(arr.arrayGet(u), target)) return .{ .normal = num.v(u) };
        }
        return .{ .normal = .{ .number = -1 } };
    }
    if (eql(u8, name, "includes")) { // §23.1.3.16 (SameValueZero, visits holes as undefined)
        if (len == 0) return .{ .normal = .{ .boolean = false } }; // §step 3: before ToInteger(fromIndex)
        const target: Value = if (args.len > 0) args[0] else .undefined;
        var i: usize = if (args.len > 1) switch (try fromIndexStart(it, args[1], len)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        } else 0;
        while (i < len) : (i += 1) {
            if (ops.sameValueZero(arr.arrayGet(i), target)) return .{ .normal = .{ .boolean = true } };
        }
        return .{ .normal = .{ .boolean = false } };
    }

    // ── join / toString ────────────────────────────────────────────────────────────────────────
    if (eql(u8, name, "join") or eql(u8, name, "toString")) { // §23.1.3.17 / §23.1.3.36
        const sep = if (eql(u8, name, "join") and args.len > 0 and args[0] != .undefined) try it.toString(args[0]) else ",";
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try buf.appendSlice(it.arena, sep);
            const el = arr.arrayGet(i);
            if (el != .undefined and el != .null) try buf.appendSlice(it.arena, try it.toString(el));
        }
        return .{ .normal = .{ .string = buf.items } };
    }

    // ── slicing / element access ─────────────────────────────────────────────────────────────────
    if (eql(u8, name, "at")) { // §23.1.3.1
        var k: f64 = switch (try toIntArg(it, if (args.len > 0) args[0] else .undefined, 0)) {
            .abrupt => |c| return c,
            .value => |x| x,
        };
        if (k < 0) k += @floatFromInt(len);
        if (k < 0 or k >= @as(f64, @floatFromInt(len))) return .{ .normal = .undefined };
        return .{ .normal = arr.arrayGet(@intFromFloat(k)) };
    }
    if (eql(u8, name, "slice")) { // §23.1.3.28
        const start = switch (try relIndex(it, if (args.len > 0) args[0] else .undefined, len, 0)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        const end = switch (try relIndex(it, if (args.len > 1) args[1] else .undefined, len, len)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        // §23.1.3.28 step 7: A = ArraySpeciesCreate(O, count). Populate via CreateDataPropertyOrThrow.
        const count: usize = if (end > start) end - start else 0;
        const ac = try it.arraySpeciesCreate(arr, count);
        if (ac.isAbrupt()) return ac;
        const out = ac.normal.object;
        var n: usize = 0;
        var i = start;
        while (i < end) : (i += 1) {
            if (arr.arrayHas(i)) if (try cdp(it, out, n, arr.arrayGet(i))) |c| return c;
            n += 1;
        }
        if (out.kind == .array and out.arrayLen() != count) try out.arraySetLen(count);
        return .{ .normal = .{ .object = out } };
    }
    if (eql(u8, name, "concat")) { // §23.1.3.2 (M-subset: spreadable iff Array)
        // §23.1.3.2 step 1: A = ArraySpeciesCreate(O, 0). Populate via CreateDataPropertyOrThrow.
        const ac = try it.arraySpeciesCreate(arr, 0);
        if (ac.isAbrupt()) return ac;
        const out = ac.normal.object;
        var n: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (arr.arrayHas(i)) if (try cdp(it, out, n, arr.arrayGet(i))) |c| return c;
            n += 1;
        }
        for (args) |a| {
            if (a == .object and a.object.kind == .array) {
                const al = a.object.arrayLen();
                var j: usize = 0;
                while (j < al) : (j += 1) {
                    if (a.object.arrayHas(j)) if (try cdp(it, out, n, a.object.arrayGet(j))) |c| return c;
                    n += 1;
                }
            } else {
                if (try cdp(it, out, n, a)) |c| return c;
                n += 1;
            }
        }
        if (out.kind == .array and out.arrayLen() != n) try out.arraySetLen(n);
        return .{ .normal = .{ .object = out } };
    }

    // ── mutation: reverse / fill / copyWithin / splice ───────────────────────────────────────────
    if (eql(u8, name, "reverse")) { // §23.1.3.26 (Set/Delete with Throw=true → frozen array TypeErrors)
        if (len > 1) {
            var lo: usize = 0;
            var hi: usize = len - 1;
            while (lo < hi) {
                const a = arr.arrayGet(lo);
                const b = arr.arrayGet(hi);
                if (try setT(it, arr, lo, b)) |c| return c;
                if (try setT(it, arr, hi, a)) |c| return c;
                lo += 1;
                hi -= 1;
            }
        }
        return .{ .normal = this_val };
    }
    if (eql(u8, name, "fill")) { // §23.1.3.8 (visits holes; Set with Throw=true)
        const value: Value = if (args.len > 0) args[0] else .undefined;
        const start = switch (try relIndex(it, if (args.len > 1) args[1] else .undefined, len, 0)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        const end = switch (try relIndex(it, if (args.len > 2) args[2] else .undefined, len, len)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        var i = start;
        while (i < end) : (i += 1) if (try setT(it, arr, i, value)) |c| return c;
        return .{ .normal = this_val };
    }
    if (eql(u8, name, "copyWithin")) { // §23.1.3.4
        const to = switch (try relIndex(it, if (args.len > 0) args[0] else .undefined, len, 0)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        const from = switch (try relIndex(it, if (args.len > 1) args[1] else .undefined, len, 0)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        const final = switch (try relIndex(it, if (args.len > 2) args[2] else .undefined, len, len)) {
            .abrupt => |c| return c,
            .idx => |x| x,
        };
        var count: usize = if (final > from) @min(final - from, len - to) else 0;
        // Copy forward or backward depending on overlap (spec uses a direction flag).
        if (from < to and to < from + count) {
            // backward
            var f = from + count;
            var t = to + count;
            while (count > 0) : (count -= 1) {
                f -= 1;
                t -= 1;
                if (arr.arrayHas(f)) {
                    if (try setT(it, arr, t, arr.arrayGet(f))) |c| return c;
                } else if (try delT(it, arr, t)) |c| return c;
            }
        } else {
            var f = from;
            var t = to;
            while (count > 0) : (count -= 1) {
                if (arr.arrayHas(f)) {
                    if (try setT(it, arr, t, arr.arrayGet(f))) |c| return c;
                } else if (try delT(it, arr, t)) |c| return c;
                f += 1;
                t += 1;
            }
        }
        return .{ .normal = this_val };
    }
    if (eql(u8, name, "splice")) return splice(it, arr, len, args);

    // ── callback: iteration / search (require a callable first arg) ──────────────────────────────
    if (eql(u8, name, "forEach") or eql(u8, name, "map") or eql(u8, name, "filter") or
        eql(u8, name, "some") or eql(u8, name, "every") or eql(u8, name, "find") or
        eql(u8, name, "findIndex") or eql(u8, name, "findLast") or eql(u8, name, "findLastIndex") or
        eql(u8, name, "flatMap"))
    {
        if (args.len == 0 or args[0] != .object or !isCallable(args[0].object)) {
            return it.throwError("TypeError", "callback is not a function");
        }
        const cb = args[0].object;
        const this_arg: Value = if (args.len > 1) args[1] else .undefined;
        return callbackMethod(it, name, this_val, arr, len, cb, this_arg);
    }

    // ── reduce / reduceRight ─────────────────────────────────────────────────────────────────────
    if (eql(u8, name, "reduce") or eql(u8, name, "reduceRight")) {
        if (args.len == 0 or args[0] != .object or !isCallable(args[0].object)) {
            return it.throwError("TypeError", "callback is not a function");
        }
        return reduce(it, eql(u8, name, "reduceRight"), this_val, arr, len, args[0].object, if (args.len > 1) args[1] else null);
    }

    // ── flat ─────────────────────────────────────────────────────────────────────────────────────
    if (eql(u8, name, "flat")) { // §23.1.3.11
        const depth: f64 = if (args.len > 0 and args[0] != .undefined) @trunc(ops.toNumber(args[0])) else 1;
        // §23.1.3.11 step 4: A = ArraySpeciesCreate(O, 0); FlattenIntoArray populates via
        // CreateDataPropertyOrThrow at a running target index.
        const ac = try it.arraySpeciesCreate(arr, 0);
        if (ac.isAbrupt()) return ac;
        const out = ac.normal.object;
        var target: usize = 0;
        const fc = try flatten(it, out, &target, arr, len, depth);
        if (fc.isAbrupt()) return fc;
        if (out.kind == .array and out.arrayLen() != target) try out.arraySetLen(target);
        return .{ .normal = .{ .object = out } };
    }

    // ── sort ─────────────────────────────────────────────────────────────────────────────────────
    if (eql(u8, name, "sort")) return sort(it, this_val, arr, len, if (args.len > 0) args[0] else .undefined);

    // values/keys/entries are separate natives (array_values/keys/entries); unknown → undefined.
    return .{ .normal = .undefined };
}

fn isCallable(o: *Object) bool {
    return o.kind == .function;
}

// ── Throw=true write wrappers ────────────────────────────────────────────────────────────────────
// The interpreter's CreateDataPropertyOrThrow / array-[[Set]]-with-Throw helpers return a Completion
// (`.normal=undefined` on success, `.thrown` on a frozen/non-extensible rejection). These thin wrappers
// return `?Completion` — null on success, the abrupt completion to propagate otherwise — so call sites
// read `if (try cdp(...)) |c| return c;`.

fn cdp(it: *Interpreter, out: *Object, index: usize, v: Value) EvalError!?Completion {
    const c = try it.createDataPropertyOrThrow(out, index, v);
    return if (c.isAbrupt()) c else null;
}
fn setT(it: *Interpreter, arr: *Object, index: usize, v: Value) EvalError!?Completion {
    const c = try it.arraySetThrow(arr, index, v);
    return if (c.isAbrupt()) c else null;
}
fn setLenT(it: *Interpreter, arr: *Object, n: usize) EvalError!?Completion {
    const c = try it.arraySetLenThrow(arr, n);
    return if (c.isAbrupt()) c else null;
}
fn delT(it: *Interpreter, arr: *Object, index: usize) EvalError!?Completion {
    const c = try arrayDeleteThrow(it, arr, index);
    return if (c.isAbrupt()) c else null;
}

fn deleteIdx(arr: *Object, i: usize) std.mem.Allocator.Error!void {
    try arr.arrayDelete(i);
}

/// §10.4.2.x DeletePropertyOrThrow of an index during a mutation (splice tail-shift): a frozen array's
/// non-configurable index cannot be deleted → TypeError; otherwise leave a true hole. Returns the
/// abrupt `.thrown` completion (or `.normal = undefined`).
fn arrayDeleteThrow(it: *Interpreter, arr: *Object, i: usize) EvalError!Completion {
    if (arr.array_frozen) return it.throwError("TypeError", "Cannot delete property of a frozen array");
    try arr.arrayDelete(i);
    return .{ .normal = .undefined };
}

/// §Get(O, ToString(i)): an own dense/sparse value if present, else through the prototype chain (so an
/// inherited index is read, matching the spec's `Get` step in the iteration/search family).
fn arrayGetChain(it: *Interpreter, arr: *Object, i: usize) EvalError!Completion {
    if (arr.arrayHas(i)) return .{ .normal = arr.arrayGet(i) };
    return it.getProperty2(.{ .object = arr }, try numToKey(it.arena, i));
}

/// §23.1.3 dispatch for the callback-taking iteration/search methods. `cb` is callable; holes are
/// skipped for forEach/map/filter/some/every/flatMap, visited (as undefined) for find*.
fn callbackMethod(it: *Interpreter, name: []const u8, this_val: Value, arr: *Object, len: usize, cb: *Object, this_arg: Value) EvalError!Completion {
    const eql = std.mem.eql;
    const visit_holes = eql(u8, name, "find") or eql(u8, name, "findIndex") or
        eql(u8, name, "findLast") or eql(u8, name, "findLastIndex");
    const reverse = eql(u8, name, "findLast") or eql(u8, name, "findLastIndex");

    // §23.1.3.x: map → ArraySpeciesCreate(O, len); filter / flatMap → ArraySpeciesCreate(O, 0). The
    // result is populated via CreateDataPropertyOrThrow (a frozen / non-extensible species result throws).
    const is_map = eql(u8, name, "map");
    const is_filter = eql(u8, name, "filter");
    const is_flatmap = eql(u8, name, "flatMap");
    const out: ?*Object = if (is_map or is_filter or is_flatmap) blk: {
        const ac = try it.arraySpeciesCreate(arr, if (is_map) len else 0);
        if (ac.isAbrupt()) return ac;
        break :blk ac.normal.object;
    } else null;
    var dst: usize = 0; // running destination index for filter / flatMap (dense output)

    var idx: usize = 0;
    while (idx < len) : (idx += 1) {
        const i = if (reverse) len - 1 - idx else idx;
        // §23.1.3.x: forEach/map/filter/some/every/flatMap visit indices for which HasProperty (own OR
        // inherited via the prototype chain) is true; find* visit every index 0..len regardless.
        const present = if (visit_holes) true else it.arrayHasPropertyChain(arr, i);
        if (!present) continue;
        // §Get(O, Pk): read through the chain so an inherited index (e.g. via Array.prototype[i]) is seen.
        const el = if (arr.arrayHas(i)) arr.arrayGet(i) else blk: {
            const gc = try it.getProperty2(.{ .object = arr }, try numToKey(it.arena, i));
            if (gc.isAbrupt()) return gc;
            break :blk gc.normal;
        };
        const r = try it.callFunction(cb, &.{ el, num.v(i), this_val }, this_arg);
        if (r.isAbrupt()) return r;
        const rv = r.normal;
        if (is_map) {
            if (try cdp(it, out.?, i, rv)) |c| return c;
        } else if (is_filter) {
            if (ops.toBoolean(rv)) {
                if (try cdp(it, out.?, dst, el)) |c| return c;
                dst += 1;
            }
        } else if (is_flatmap) {
            // §23.1.3.10 FlatMap depth-1 flatten: a returned Array spreads its present elements.
            if (rv == .object and rv.object.kind == .array) {
                const al = rv.object.arrayLen();
                var j: usize = 0;
                while (j < al) : (j += 1) {
                    if (rv.object.arrayHas(j)) {
                        if (try cdp(it, out.?, dst, rv.object.arrayGet(j))) |c| return c;
                        dst += 1;
                    }
                }
            } else {
                if (try cdp(it, out.?, dst, rv)) |c| return c;
                dst += 1;
            }
        } else if (eql(u8, name, "some")) {
            if (ops.toBoolean(rv)) return .{ .normal = .{ .boolean = true } };
        } else if (eql(u8, name, "every")) {
            if (!ops.toBoolean(rv)) return .{ .normal = .{ .boolean = false } };
        } else if (eql(u8, name, "find") or eql(u8, name, "findLast")) {
            if (ops.toBoolean(rv)) return .{ .normal = el };
        } else if (eql(u8, name, "findIndex") or eql(u8, name, "findLastIndex")) {
            if (ops.toBoolean(rv)) return .{ .normal = num.v(i) };
        }
    }
    if (out) |o| {
        // §23.1.3.21 map preserves length (including the trailing-hole length); filter/flatMap are dense
        // (length = the number of CreateDataProperty calls). Only fix up a plain Array result.
        if (o.kind == .array) {
            const want: usize = if (is_map) len else dst;
            if (o.arrayLen() != want) try o.arraySetLen(want);
        }
        return .{ .normal = .{ .object = o } };
    }
    if (eql(u8, name, "some")) return .{ .normal = .{ .boolean = false } };
    if (eql(u8, name, "every")) return .{ .normal = .{ .boolean = true } };
    if (eql(u8, name, "find") or eql(u8, name, "findLast")) return .{ .normal = .undefined };
    if (eql(u8, name, "findIndex") or eql(u8, name, "findLastIndex")) return .{ .normal = .{ .number = -1 } };
    return .{ .normal = .undefined }; // forEach
}

/// §23.1.3.24 / §23.1.3.25 reduce / reduceRight. Skips holes; a missing initial value with no present
/// element → TypeError.
fn reduce(it: *Interpreter, right: bool, this_val: Value, arr: *Object, len: usize, cb: *Object, init: ?Value) EvalError!Completion {
    var acc: Value = if (init) |v| v else .undefined;
    var have_acc = init != null;
    var idx: usize = 0;
    // First, if no initial value, seed from the first present element (from the appropriate end).
    if (!have_acc) {
        var found = false;
        while (idx < len) : (idx += 1) {
            const i = if (right) len - 1 - idx else idx;
            if (it.arrayHasPropertyChain(arr, i)) {
                const ec = try arrayGetChain(it, arr, i);
                if (ec.isAbrupt()) return ec;
                acc = ec.normal;
                have_acc = true;
                found = true;
                idx += 1;
                break;
            }
        }
        if (!found) return it.throwError("TypeError", "Reduce of empty array with no initial value");
    }
    while (idx < len) : (idx += 1) {
        const i = if (right) len - 1 - idx else idx;
        if (!it.arrayHasPropertyChain(arr, i)) continue;
        const ec = try arrayGetChain(it, arr, i);
        if (ec.isAbrupt()) return ec;
        const r = try it.callFunction(cb, &.{ acc, ec.normal, num.v(i), this_val }, .undefined);
        if (r.isAbrupt()) return r;
        acc = r.normal;
    }
    return .{ .normal = acc };
}

/// §23.1.3.11.1 FlattenIntoArray (M-subset: source elements only, no mapper). Appends each non-nested
/// element to `out` at the running `target` index via CreateDataPropertyOrThrow (so a frozen /
/// non-extensible species result throws); recurses into nested arrays up to `depth`.
fn flatten(it: *Interpreter, out: *Object, target: *usize, arr: *Object, len: usize, depth: f64) EvalError!Completion {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!arr.arrayHas(i)) continue;
        const el = arr.arrayGet(i);
        if (depth > 0 and el == .object and el.object.kind == .array) {
            const c = try flatten(it, out, target, el.object, el.object.arrayLen(), depth - 1);
            if (c.isAbrupt()) return c;
        } else {
            if (try cdp(it, out, target.*, el)) |c| return c;
            target.* += 1;
        }
    }
    return .{ .normal = .undefined };
}

/// §23.1.3.30 splice(start, deleteCount, ...items). Returns an Array of the removed elements; mutates
/// `arr` in place.
fn splice(it: *Interpreter, arr: *Object, len: usize, args: []const Value) EvalError!Completion {
    const start = switch (try relIndex(it, if (args.len > 0) args[0] else .undefined, len, 0)) {
        .abrupt => |c| return c,
        .idx => |x| x,
    };
    const del_count: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - start
    else blk: {
        const dc = switch (try toIntArg(it, args[1], 0)) {
            .abrupt => |c| return c,
            .value => |x| x,
        };
        if (dc < 0) break :blk 0;
        if (dc > @as(f64, @floatFromInt(len - start))) break :blk len - start;
        break :blk @intFromFloat(dc);
    };
    const items: []const Value = if (args.len > 2) args[2..] else &.{};

    // §23.1.3.30 step 9: A = ArraySpeciesCreate(O, actualDeleteCount). Populate via CreateDataProperty.
    const ac = try it.arraySpeciesCreate(arr, del_count);
    if (ac.isAbrupt()) return ac;
    const removed = ac.normal.object;
    var k: usize = 0;
    while (k < del_count) : (k += 1) {
        if (arr.arrayHas(start + k)) if (try cdp(it, removed, k, arr.arrayGet(start + k))) |c| return c;
    }
    if (removed.kind == .array and removed.arrayLen() != del_count) try removed.arraySetLen(del_count);

    // The receiver mutation uses the Throw=true element/length [[Set]] — a frozen / non-extensible array
    // rejects (TypeError) before any element is moved.
    const new_len = len - del_count + items.len;
    if (items.len < del_count) {
        // shrink: shift the tail left
        var i = start;
        while (i < len - del_count) : (i += 1) {
            const from = i + del_count;
            const to = i + items.len;
            if (arr.arrayHas(from)) {
                if (try setT(it, arr, to, arr.arrayGet(from))) |c| return c;
            } else if (try delT(it, arr, to)) |c| return c;
        }
        // delete the now-vacated tail slots [new_len, len) before shrinking length
        var d = len;
        while (d > new_len) : (d -= 1) if (try delT(it, arr, d - 1)) |c| return c;
        if (try setLenT(it, arr, new_len)) |c| return c;
    } else if (items.len > del_count) {
        // grow: shift the tail right, from the top down
        var i = len - del_count;
        while (i > start) : (i -= 1) {
            const from = i + del_count - 1;
            const to = i + items.len - 1;
            if (arr.arrayHas(from)) {
                if (try setT(it, arr, to, arr.arrayGet(from))) |c| return c;
            } else if (try delT(it, arr, to)) |c| return c;
        }
    }
    for (items, 0..) |item, j| if (try setT(it, arr, start + j, item)) |c| return c;
    if (arr.arrayLen() != new_len) if (try setLenT(it, arr, new_len)) |c| return c;
    return .{ .normal = .{ .object = removed } };
}

/// §23.1.3.30 sort(comparefn). Default comparator = ToString ascending; an optional comparator
/// function. holes + undefined sort to the end (§23.1.3.30 SortIndexedProperties).
fn sort(it: *Interpreter, this_val: Value, arr: *Object, len: usize, comparefn: Value) EvalError!Completion {
    if (comparefn != .undefined and (comparefn != .object or !isCallable(comparefn.object))) {
        return it.throwError("TypeError", "comparator is not a function");
    }
    // Collect the present, non-undefined values; count holes + undefineds to append at the end.
    var vals: std.ArrayListUnmanaged(Value) = .empty;
    var undef_count: usize = 0;
    var hole_count: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!arr.arrayHas(i)) {
            hole_count += 1;
            continue;
        }
        const el = arr.arrayGet(i);
        if (el == .undefined) undef_count += 1 else try vals.append(it.arena, el);
    }
    // Insertion sort (stable, and tolerant of a comparator with side effects / abrupt completion).
    var a = vals.items;
    var j: usize = 1;
    while (j < a.len) : (j += 1) {
        const key = a[j];
        var m: usize = j;
        while (m > 0) : (m -= 1) {
            const cmp = try compare(it, comparefn, a[m - 1], key);
            switch (cmp) {
                .abrupt => |c| return c,
                .order => |o| if (o <= 0) break else {
                    a[m] = a[m - 1];
                },
            }
        }
        a[m] = key;
    }
    // Write back: sorted values, then undefineds, then truncate to drop holes (they become trailing).
    // Set/Delete use the Throw=true form so sorting a frozen array TypeErrors.
    i = 0;
    for (a) |v| {
        if (try setT(it, arr, i, v)) |c| return c;
        i += 1;
    }
    var u: usize = 0;
    while (u < undef_count) : (u += 1) {
        if (try setT(it, arr, i, .undefined)) |c| return c;
        i += 1;
    }
    // The remaining `hole_count` slots become holes by leaving the length as `len` and deleting them.
    var h: usize = 0;
    while (h < hole_count) : (h += 1) {
        if (try delT(it, arr, i)) |c| return c;
        i += 1;
    }
    if (arr.arrayLen() != len) try arr.arraySetLen(len);
    return .{ .normal = this_val };
}

const CompareResult = union(enum) { order: i32, abrupt: Completion };

/// §23.1.3.30.1 SortCompare: with a comparator → its sign; else ToString ascending.
fn compare(it: *Interpreter, comparefn: Value, x: Value, y: Value) EvalError!CompareResult {
    if (comparefn == .object) {
        const r = try it.callFunction(comparefn.object, &.{ x, y }, .undefined);
        if (r.isAbrupt()) return .{ .abrupt = r };
        const n = ops.toNumber(r.normal);
        if (std.math.isNan(n)) return .{ .order = 0 };
        return .{ .order = if (n < 0) @as(i32, -1) else if (n > 0) @as(i32, 1) else 0 };
    }
    const xs = try it.toString(x);
    const ys = try it.toString(y);
    return .{ .order = switch (std.mem.order(u8, xs, ys)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } };
}

/// §23.1.2.1 Array.from(items, mapFn?, thisArg?) — from an iterable or array-like.
/// §23.1.2.2 Array.of(...items). `this_val` is the static call's `this` (the target constructor `C`):
/// `IsConstructor(C) ? Construct(C, «len») : ArrayCreate(len)`, then the result is populated via
/// CreateDataPropertyOrThrow (so a constructor returning a non-extensible / locked object throws).
pub fn staticCall(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "of")) { // §23.1.2.2
        const ac = try it.arrayCreateFromCtor(this_val, args.len);
        if (ac.isAbrupt()) return ac;
        const out = ac.normal.object;
        for (args, 0..) |a, k| if (try cdp(it, out, k, a)) |c| return c;
        // §23.1.2.2 step 8: Set(A, "length", len, true) — for a custom constructor result this records
        // the final length; the plain Array already tracks it via the index sets.
        if (out.kind != .array) {
            const sc = try it.setPropertyPub(.{ .object = out }, "length", num.v(args.len));
            if (sc.isAbrupt()) return sc;
        }
        return .{ .normal = .{ .object = out } };
    }
    // from
    const items: Value = if (args.len > 0) args[0] else .undefined;
    const map_fn: ?*Object = blk: {
        if (args.len > 1 and args[1] != .undefined) {
            if (args[1] != .object or !isCallable(args[1].object)) {
                return it.throwError("TypeError", "Array.from: mapFn is not a function");
            }
            break :blk args[1].object;
        }
        break :blk null;
    };
    const this_arg: Value = if (args.len > 2) args[2] else .undefined;
    if (items == .undefined or items == .null) {
        return it.throwError("TypeError", "Array.from requires an array-like or iterable object");
    }
    // Iterable (string or has @@iterator) → A = arrayCreateFromCtor(C, 0); step the iterator AND apply
    // mapFn as we go, CreateDataPropertyOrThrow onto A (a throwing mapFn / abrupt next stops immediately
    // and closes the iterator — never drains, never OOMs).
    if (items == .string or (items == .object and try it.isArrayFromIterable(items))) {
        const ac = try it.arrayCreateFromCtor(this_val, 0);
        if (ac.isAbrupt()) return ac;
        const out = ac.normal.object;
        const c = try it.arrayFromIterate(items, out, map_fn, this_arg);
        if (c.isAbrupt()) return c;
        return .{ .normal = .{ .object = out } };
    }
    // Array-like: LengthOfArrayLike(items); A = arrayCreateFromCtor(C, len); read indices 0..len.
    const lc = try it.getProperty2(items, "length");
    if (lc.isAbrupt()) return lc;
    // §7.1.20 LengthOfArrayLike = ToLength(Get(items,"length")) — ToNumber is throwing (a Symbol/BigInt
    // length → TypeError), then clamp to [0, 2^53-1].
    const lnc = try it.toNumberThrowing(lc.normal);
    if (lnc.isAbrupt()) return lnc;
    const flen = lnc.normal.number;
    const max_len: f64 = 9007199254740991.0; // 2^53 - 1
    const alen: usize = if (std.math.isNan(flen) or flen <= 0) 0 else if (flen > max_len) @intFromFloat(max_len) else @intFromFloat(@trunc(flen));
    const ac = try it.arrayCreateFromCtor(this_val, alen);
    if (ac.isAbrupt()) return ac;
    const out = ac.normal.object;
    var k: usize = 0;
    while (k < alen) : (k += 1) {
        const key = try numToKey(it.arena, k);
        const ec = try it.getProperty2(items, key);
        if (ec.isAbrupt()) return ec;
        const mapped = if (map_fn) |f| blk: {
            const r = try it.callFunction(f, &.{ ec.normal, num.v(k) }, this_arg);
            if (r.isAbrupt()) return r;
            break :blk r.normal;
        } else ec.normal;
        if (try cdp(it, out, k, mapped)) |c| return c;
    }
    // §23.1.2.1 step 12.h-13: Set(A, "length", len, true).
    if (out.kind == .array) {
        if (out.arrayLen() != alen) try out.arraySetLen(alen);
    } else {
        const sc = try it.setPropertyPub(.{ .object = out }, "length", num.v(alen));
        if (sc.isAbrupt()) return sc;
    }
    return .{ .normal = .{ .object = out } };
}

fn numToKey(arena: std.mem.Allocator, k: usize) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{k});
}

/// §7.1.5 ToIntegerOrInfinity over a method arg — throwing (a Symbol/BigInt operand → TypeError, so
/// `slice(Symbol())` etc. reproduce the spec's observable abrupt completion). `undefined` → `default`
/// (used where the spec's default differs from 0). Returns the truncated f64, or the abrupt completion.
const IntResult = union(enum) { value: f64, abrupt: Completion };
fn toIntArg(it: *Interpreter, v: Value, default: f64) EvalError!IntResult {
    if (v == .undefined) return .{ .value = default };
    const c = try it.toNumberThrowing(v);
    if (c.isAbrupt()) return .{ .abrupt = c };
    const n = c.normal.number;
    if (std.math.isNan(n)) return .{ .value = 0 };
    return .{ .value = @trunc(n) };
}

/// §23.1.3 relative index (negative counts from the end), clamped to [0, len]. Throwing arg coercion.
fn relIndex(it: *Interpreter, v: Value, len: usize, default: usize) EvalError!RelResult {
    const ir = try toIntArg(it, v, @floatFromInt(default));
    const n = switch (ir) {
        .abrupt => |c| return .{ .abrupt = c },
        .value => |x| x,
    };
    const flen: f64 = @floatFromInt(len);
    var idx = n;
    if (idx < 0) idx += flen;
    if (idx < 0) idx = 0;
    if (idx > flen) idx = flen;
    return .{ .idx = @intFromFloat(idx) };
}
const RelResult = union(enum) { idx: usize, abrupt: Completion };

/// §23.1.3.14 indexOf/includes fromIndex (forward): a negative value counts from the end. Throwing.
fn fromIndexStart(it: *Interpreter, v: Value, len: usize) EvalError!RelResult {
    return relIndex(it, v, len, 0);
}

/// §23.1.3.19 lastIndexOf fromIndex (backward): default len-1; negative counts from the end. Throwing.
const LastResult = union(enum) { idx: isize, abrupt: Completion };
fn fromIndexLast(it: *Interpreter, v: Value, len: usize) EvalError!LastResult {
    const ir = try toIntArg(it, v, @as(f64, @floatFromInt(len)) - 1);
    var idx = switch (ir) {
        .abrupt => |c| return .{ .abrupt = c },
        .value => |x| x,
    };
    const flen: f64 = @floatFromInt(len);
    if (idx < 0) idx += flen;
    if (idx >= flen) idx = flen - 1;
    if (idx < 0) return .{ .idx = -1 };
    return .{ .idx = @intFromFloat(idx) };
}
