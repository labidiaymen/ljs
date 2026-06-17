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
    if (eql(u8, name, "push")) {
        for (args) |a| try arr.arrayPush(it.arena, a);
        return .{ .normal = num.v(arr.arrayLen()) };
    }
    if (eql(u8, name, "pop")) {
        if (len == 0) return .{ .normal = .undefined };
        const last = arr.arrayGet(len - 1);
        try arr.arraySetLen(len - 1);
        return .{ .normal = last };
    }
    if (eql(u8, name, "shift")) { // §23.1.3.27
        if (len == 0) return .{ .normal = .undefined };
        const first = arr.arrayGet(0);
        var i: usize = 1;
        while (i < len) : (i += 1) try arr.arraySet(it.arena, i - 1, arr.arrayGet(i));
        try arr.arraySetLen(len - 1);
        return .{ .normal = first };
    }
    if (eql(u8, name, "unshift")) { // §23.1.3.33
        const argc = args.len;
        if (argc > 0) {
            // Shift existing elements up by argc, from the top down.
            var i: usize = len;
            while (i > 0) : (i -= 1) try arr.arraySet(it.arena, i - 1 + argc, arr.arrayGet(i - 1));
            for (args, 0..) |a, j| try arr.arraySet(it.arena, j, a);
        }
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
        const out = try Object.createArray(it.arena, it.arrayProto());
        var i = start;
        while (i < end) : (i += 1) try out.arrayPush(it.arena, arr.arrayGet(i));
        return .{ .normal = .{ .object = out } };
    }
    if (eql(u8, name, "concat")) { // §23.1.3.2 (M-subset: spreadable iff Array)
        const out = try Object.createArray(it.arena, it.arrayProto());
        var i: usize = 0;
        while (i < len) : (i += 1) try out.arrayPush(it.arena, arr.arrayGet(i));
        for (args) |a| {
            if (a == .object and a.object.kind == .array) {
                const al = a.object.arrayLen();
                var j: usize = 0;
                while (j < al) : (j += 1) try out.arrayPush(it.arena, a.object.arrayGet(j));
            } else try out.arrayPush(it.arena, a);
        }
        return .{ .normal = .{ .object = out } };
    }

    // ── mutation: reverse / fill / copyWithin / splice ───────────────────────────────────────────
    if (eql(u8, name, "reverse")) { // §23.1.3.26
        if (len > 1) {
            var lo: usize = 0;
            var hi: usize = len - 1;
            while (lo < hi) {
                const a = arr.arrayGet(lo);
                const b = arr.arrayGet(hi);
                try arr.arraySet(it.arena, lo, b);
                try arr.arraySet(it.arena, hi, a);
                lo += 1;
                hi -= 1;
            }
        }
        return .{ .normal = this_val };
    }
    if (eql(u8, name, "fill")) { // §23.1.3.8 (visits holes)
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
        while (i < end) : (i += 1) try arr.arraySet(it.arena, i, value);
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
                if (arr.arrayHas(f)) try arr.arraySet(it.arena, t, arr.arrayGet(f)) else try deleteIdx(arr, t);
            }
        } else {
            var f = from;
            var t = to;
            while (count > 0) : (count -= 1) {
                if (arr.arrayHas(f)) try arr.arraySet(it.arena, t, arr.arrayGet(f)) else try deleteIdx(arr, t);
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
        const out = try Object.createArray(it.arena, it.arrayProto());
        try flatten(it, out, arr, len, depth);
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

fn deleteIdx(arr: *Object, i: usize) std.mem.Allocator.Error!void {
    try arr.arrayDelete(i);
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

    const out: ?*Object = if (eql(u8, name, "map") or eql(u8, name, "filter") or eql(u8, name, "flatMap"))
        try Object.createArray(it.arena, it.arrayProto())
    else
        null;

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
        if (eql(u8, name, "map")) {
            try out.?.arraySet(it.arena, i, rv);
        } else if (eql(u8, name, "filter")) {
            if (ops.toBoolean(rv)) try out.?.arrayPush(it.arena, el);
        } else if (eql(u8, name, "flatMap")) {
            if (rv == .object and rv.object.kind == .array) {
                const al = rv.object.arrayLen();
                var j: usize = 0;
                while (j < al) : (j += 1) try out.?.arrayPush(it.arena, rv.object.arrayGet(j));
            } else try out.?.arrayPush(it.arena, rv);
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
        // §23.1.3.21 map preserves length (including the trailing-hole length); filter/flatMap are dense.
        if (eql(u8, name, "map") and o.arrayLen() < len) try o.arraySetLen(len);
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

/// §23.1.3.11.1 FlattenIntoArray (M-subset: source elements only, no mapper).
fn flatten(it: *Interpreter, out: *Object, arr: *Object, len: usize, depth: f64) EvalError!void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!arr.arrayHas(i)) continue;
        const el = arr.arrayGet(i);
        if (depth > 0 and el == .object and el.object.kind == .array) {
            try flatten(it, out, el.object, el.object.arrayLen(), depth - 1);
        } else {
            try out.arrayPush(it.arena, el);
        }
    }
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

    const removed = try Object.createArray(it.arena, it.arrayProto());
    var k: usize = 0;
    while (k < del_count) : (k += 1) try removed.arrayPush(it.arena, arr.arrayGet(start + k));

    const new_len = len - del_count + items.len;
    if (items.len < del_count) {
        // shrink: shift the tail left
        var i = start;
        while (i < len - del_count) : (i += 1) {
            const from = i + del_count;
            const to = i + items.len;
            if (arr.arrayHas(from)) try arr.arraySet(it.arena, to, arr.arrayGet(from)) else try deleteIdx(arr, to);
        }
        try arr.arraySetLen(new_len);
    } else if (items.len > del_count) {
        // grow: shift the tail right, from the top down
        var i = len - del_count;
        while (i > start) : (i -= 1) {
            const from = i + del_count - 1;
            const to = i + items.len - 1;
            if (arr.arrayHas(from)) try arr.arraySet(it.arena, to, arr.arrayGet(from)) else try deleteIdx(arr, to);
        }
    }
    for (items, 0..) |item, j| try arr.arraySet(it.arena, start + j, item);
    if (arr.arrayLen() != new_len) try arr.arraySetLen(new_len);
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
    i = 0;
    for (a) |v| {
        try arr.arraySet(it.arena, i, v);
        i += 1;
    }
    var u: usize = 0;
    while (u < undef_count) : (u += 1) {
        try arr.arraySet(it.arena, i, .undefined);
        i += 1;
    }
    // The remaining `hole_count` slots become holes by leaving the length as `len` and deleting them.
    var h: usize = 0;
    while (h < hole_count) : (h += 1) {
        try deleteIdx(arr, i);
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
/// §23.1.2.3 Array.of(...items).
pub fn staticCall(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "of")) {
        const out = try Object.createArray(it.arena, it.arrayProto());
        for (args) |a| try out.arrayPush(it.arena, a);
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
    const out = try Object.createArray(it.arena, it.arrayProto());
    // Iterable (string or has @@iterator) → step the iterator AND apply mapFn as we go (so a throwing
    // mapFn / abrupt next stops immediately and closes the iterator — never drains, never OOMs).
    if (items == .string or (items == .object and try it.isArrayFromIterable(items))) {
        const c = try it.arrayFromIterate(items, out, map_fn, this_arg);
        if (c.isAbrupt()) return c;
        return .{ .normal = .{ .object = out } };
    }
    // Array-like: LengthOfArrayLike(items) then read indices 0..len.
    const lc = try it.getProperty2(items, "length");
    if (lc.isAbrupt()) return lc;
    const flen = ops.toNumber(lc.normal);
    const alen: usize = if (std.math.isNan(flen) or flen <= 0) 0 else if (flen > 4294967295.0) 4294967295 else @intFromFloat(@trunc(flen));
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
        try out.arrayPush(it.arena, mapped);
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
