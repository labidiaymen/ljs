//! §21.2 BigInt — the constructor (callable, not `new`), the prototype methods (toString/valueOf/
//! toLocaleString), the statics (asIntN/asUintN), and §7.1.13 ToBigInt. Dispatched from the
//! interpreter's `callNative`. Lives in its own file so the interpreter stays the evaluator.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const bigint = @import("bigint.zig");
const ops = @import("abstract_ops.zig");
const toNumber = ops.toNumber;

/// §7.1.13 ToBigInt — a primitive `prim` (after ToPrimitive) to a BigInt, or an abrupt completion
/// carrying the right exception. Boolean→0n/1n, BigInt→itself, String→StringToBigInt (invalid →
/// SyntaxError), Number→NumberToBigInt (non-integer → RangeError), Symbol/Number-NaN handled.
/// undefined/null → TypeError. Returns `.{ .normal = .bigint }` on success.
fn toBigIntPrim(it: *Interpreter, prim: Value) EvalError!Completion {
    switch (prim) {
        .bigint => return .{ .normal = prim },
        .boolean => |b| return .{ .normal = .{ .bigint = bigint.fromI64(it.arena, if (b) 1 else 0) catch |e| return it.bigintError(e) } },
        .number => |n| return .{ .normal = .{ .bigint = bigint.fromF64(it.arena, n) catch |e| return it.bigintError(e) } },
        .string => |s| {
            const maybe = bigint.fromString(it.arena, s) catch |e| return it.bigintError(e);
            const b = maybe orelse return it.throwError("SyntaxError", "Cannot convert string to a BigInt");
            return .{ .normal = .{ .bigint = b } };
        },
        .symbol => return it.throwError("TypeError", "Cannot convert a Symbol value to a BigInt"),
        .undefined, .null => return it.throwError("TypeError", "Cannot convert undefined or null to a BigInt"),
        .object => unreachable, // caller ToPrimitive'd first
    }
}

/// §21.2.1.1 BigInt ( value ) — ToPrimitive(number) the argument, then ToBigInt.
pub fn bigintConstructor(it: *Interpreter, args: []const Value) EvalError!Completion {
    const v: Value = if (args.len > 0) args[0] else .undefined;
    const pc = try it.toPrimitive(v, .number);
    if (pc.isAbrupt()) return pc;
    return toBigIntPrim(it, pc.normal);
}

/// §21.2.2.1/.2 BigInt.asIntN(bits, x) / BigInt.asUintN(bits, x) — `bits` = ToIndex, `x` = ToBigInt.
pub fn bigintStatic(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const bits_arg: Value = if (args.len > 0) args[0] else .undefined;
    const x_arg: Value = if (args.len > 1) args[1] else .undefined;
    // §7.1.22 ToIndex: ToIntegerOrInfinity, must be a non-negative integer < 2^53.
    const bits_n = toNumber(bits_arg);
    if (std.math.isNan(bits_n) or bits_n < 0 or @floor(bits_n) != bits_n or bits_n > 9007199254740991.0) {
        return it.throwError("RangeError", "Invalid bit count for BigInt.asIntN/asUintN");
    }
    const bits: usize = @intFromFloat(bits_n);
    const xpc = try it.toPrimitive(x_arg, .number);
    if (xpc.isAbrupt()) return xpc;
    const xc = try toBigIntPrim(it, xpc.normal);
    if (xc.isAbrupt()) return xc;
    const x = xc.normal.bigint;
    const res = if (std.mem.eql(u8, name, "asIntN"))
        bigint.asIntN(it.arena, bits, x)
    else
        bigint.asUintN(it.arena, bits, x);
    return .{ .normal = .{ .bigint = res catch |e| return it.bigintError(e) } };
}

/// §21.2.3 BigInt.prototype.toString([radix]) / valueOf — `this` must be a BigInt (or a wrapper,
/// but the M-subset never boxes BigInt into an object, so only a primitive `this` is accepted).
pub fn bigintMethod(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const b: *const std.math.big.int.Const = switch (this_val) {
        .bigint => |x| x,
        // a `new Object(1n)` style wrapper would carry [[BigIntData]] on `.primitive`; accept it.
        .object => |o| if (o.primitive != null and o.primitive.? == .bigint) o.primitive.?.bigint else return it.throwError("TypeError", "BigInt.prototype method called on incompatible receiver"),
        else => return it.throwError("TypeError", "BigInt.prototype method called on incompatible receiver"),
    };
    if (std.mem.eql(u8, name, "valueOf")) return .{ .normal = .{ .bigint = b } };
    // toString([radix]): radix defaults to 10; otherwise ToIntegerOrInfinity in [2,36].
    var radix: u8 = 10;
    if (args.len > 0 and args[0] != .undefined) {
        const rn = toNumber(args[0]);
        if (std.math.isNan(rn) or rn < 2 or rn > 36 or @floor(rn) != rn) {
            return it.throwError("RangeError", "toString() radix must be between 2 and 36");
        }
        radix = @intFromFloat(rn);
    }
    const s = bigint.toStringRadix(it.arena, b, radix) catch |e| return it.bigintError(e);
    return .{ .normal = .{ .string = s } };
}
