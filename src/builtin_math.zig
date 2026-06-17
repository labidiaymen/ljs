//! §21.3.2 the `Math` namespace methods. Dispatched from the interpreter's `callNative` (`math_method`);
//! pure numeric operations over `ToNumber`-coerced arguments (no `this`). Lives in its own file so the
//! interpreter stays the evaluator (mirrors `builtin_array.zig` etc.).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

const toNumber = ops.toNumber;
const numToInt32 = ops.numberToInt32;
const numToUint32 = ops.numberToUint32;

pub fn call(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    // §21.3.2.27 random — no operands.
    if (std.mem.eql(u8, name, "random")) return .{ .normal = .{ .number = it.randomNext() } };

    // §21.3.2.24/.25 max/min — variadic, ToNumber each, NaN-propagating, ±0-aware.
    if (std.mem.eql(u8, name, "max")) {
        var m: f64 = -std.math.inf(f64);
        for (args) |a| {
            const v = toNumber(a);
            if (std.math.isNan(v)) return .{ .normal = .{ .number = std.math.nan(f64) } };
            // §21.3.2.24 step 4: +0 is considered larger than -0 (so max(+0,-0) = +0).
            if (v > m or (v == 0 and m == 0 and !std.math.signbit(v))) m = v;
        }
        return .{ .normal = .{ .number = m } };
    }
    if (std.mem.eql(u8, name, "min")) {
        var m: f64 = std.math.inf(f64);
        for (args) |a| {
            const v = toNumber(a);
            if (std.math.isNan(v)) return .{ .normal = .{ .number = std.math.nan(f64) } };
            // §21.3.2.25 step 4: -0 is considered smaller than +0 (so min(+0,-0) = -0).
            if (v < m or (v == 0 and m == 0 and std.math.signbit(v))) m = v;
        }
        return .{ .normal = .{ .number = m } };
    }

    // §21.3.2.18 hypot — variadic; any ±Inf operand → +Inf (even if a NaN is also present).
    if (std.mem.eql(u8, name, "hypot")) {
        var sum: f64 = 0;
        var any_nan = false;
        for (args) |a| {
            const v = toNumber(a);
            if (std.math.isInf(v)) return .{ .normal = .{ .number = std.math.inf(f64) } };
            if (std.math.isNan(v)) any_nan = true;
            sum += v * v;
        }
        if (any_nan) return .{ .normal = .{ .number = std.math.nan(f64) } };
        return .{ .normal = .{ .number = @sqrt(sum) } };
    }

    // §21.3.2.11 clz32 — ToUint32 then count leading zeros (32 for 0).
    if (std.mem.eql(u8, name, "clz32")) {
        const u: u32 = numToUint32(if (args.len > 0) toNumber(args[0]) else std.math.nan(f64));
        return .{ .normal = .{ .number = @floatFromInt(@clz(u)) } };
    }
    // §21.3.2.19 imul — ToInt32 both, multiply mod 2^32, reinterpret as Int32.
    if (std.mem.eql(u8, name, "imul")) {
        const a: i32 = numToInt32(if (args.len > 0) toNumber(args[0]) else std.math.nan(f64));
        const b: i32 = numToInt32(if (args.len > 1) toNumber(args[1]) else std.math.nan(f64));
        const prod: u32 = @as(u32, @bitCast(a)) *% @as(u32, @bitCast(b));
        return .{ .normal = .{ .number = @floatFromInt(@as(i32, @bitCast(prod))) } };
    }

    const x = if (args.len > 0) toNumber(args[0]) else std.math.nan(f64);
    const y = if (args.len > 1) toNumber(args[1]) else std.math.nan(f64);
    const r: f64 = blk: {
        if (std.mem.eql(u8, name, "pow")) break :blk std.math.pow(f64, x, y); // §21.3.2.26
        if (std.mem.eql(u8, name, "atan2")) break :blk std.math.atan2(x, y); // §21.3.2.8
        if (std.mem.eql(u8, name, "floor")) break :blk @floor(x); // §21.3.2.16
        if (std.mem.eql(u8, name, "ceil")) break :blk @ceil(x); // §21.3.2.10
        if (std.mem.eql(u8, name, "round")) { // §21.3.2.28 — half-up toward +Infinity.
            // NaN / ±0 / ±Inf pass through; a magnitude ≥ 2^52 is already integral (avoid x+0.5
            // rounding error). For x in (-0.5, 0) the result is -0, so guard the sign explicitly.
            if (std.math.isNan(x) or x == 0 or std.math.isInf(x)) break :blk x;
            if (@abs(x) >= 4503599627370496.0) break :blk x;
            if (x < 0 and x >= -0.5) break :blk -0.0; // (-0.5,0]→-0, and -0.5→-0
            break :blk @floor(x + 0.5);
        }
        if (std.mem.eql(u8, name, "trunc")) break :blk @trunc(x); // §21.3.2.38
        if (std.mem.eql(u8, name, "abs")) break :blk @abs(x); // §21.3.2.1
        if (std.mem.eql(u8, name, "sqrt")) break :blk @sqrt(x); // §21.3.2.32
        if (std.mem.eql(u8, name, "cbrt")) break :blk std.math.cbrt(x); // §21.3.2.9
        if (std.mem.eql(u8, name, "sign")) break :blk std.math.sign(x); // §21.3.2.30
        if (std.mem.eql(u8, name, "fround")) break :blk @as(f64, @as(f32, @floatCast(x))); // §21.3.2.29
        // §21.3.2.{2-7} inverse + circular trig.
        if (std.mem.eql(u8, name, "sin")) break :blk @sin(x);
        if (std.mem.eql(u8, name, "cos")) break :blk @cos(x);
        if (std.mem.eql(u8, name, "tan")) break :blk @tan(x);
        if (std.mem.eql(u8, name, "asin")) break :blk std.math.asin(x);
        if (std.mem.eql(u8, name, "acos")) break :blk std.math.acos(x);
        if (std.mem.eql(u8, name, "atan")) break :blk std.math.atan(x);
        // §21.3.2.{12-17,31-37} hyperbolic + exp/log family.
        if (std.mem.eql(u8, name, "sinh")) break :blk std.math.sinh(x);
        if (std.mem.eql(u8, name, "cosh")) break :blk std.math.cosh(x);
        if (std.mem.eql(u8, name, "tanh")) break :blk std.math.tanh(x);
        if (std.mem.eql(u8, name, "asinh")) break :blk std.math.asinh(x);
        if (std.mem.eql(u8, name, "acosh")) break :blk std.math.acosh(x);
        if (std.mem.eql(u8, name, "atanh")) break :blk std.math.atanh(x);
        if (std.mem.eql(u8, name, "exp")) break :blk @exp(x); // §21.3.2.14
        if (std.mem.eql(u8, name, "expm1")) break :blk std.math.expm1(x); // §21.3.2.15
        if (std.mem.eql(u8, name, "log")) break :blk @log(x); // §21.3.2.20
        if (std.mem.eql(u8, name, "log2")) break :blk @log2(x); // §21.3.2.23
        if (std.mem.eql(u8, name, "log10")) break :blk @log10(x); // §21.3.2.21
        if (std.mem.eql(u8, name, "log1p")) break :blk std.math.log1p(x); // §21.3.2.22
        break :blk std.math.nan(f64);
    };
    return .{ .normal = .{ .number = r } };
}
