//! §23.1.2 Array statics — `Array.from` / `Array.of`. Dispatched from the interpreter's `callNative`
//! (`array_static`). Split out of builtin_array.zig to keep files under 1000 lines; reuses that file's
//! small shared helpers (cdp / numToKey / isCallable).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const arr = @import("builtin_array.zig");
const isCallable = arr.isCallable;
const cdp = arr.cdp;
const numToKey = arr.numToKey;
const num = struct {
    fn v(n: usize) Value {
        return .{ .number = @floatFromInt(n) };
    }
};

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
