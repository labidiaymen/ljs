//! §21.1.3 `Number.prototype` methods (toString/toLocaleString/valueOf/toFixed/toExponential/
//! toPrecision). Dispatched from the interpreter's `callNative` (`number_method`); `this` is a Number
//! primitive or a Number wrapper. Lives in its own file so the interpreter stays the evaluator.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

/// §21.1.3 thisNumberValue — a Number primitive, or the [[NumberData]] of a Number wrapper, else null.
fn thisNumberValue(this_val: Value) ?f64 {
    return switch (this_val) {
        .number => |x| x,
        .object => |o| if (o.primitive != null and o.primitive.? == .number) o.primitive.?.number else null,
        else => null,
    };
}

pub fn method(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const n = thisNumberValue(this_val) orelse
        return it.throwError("TypeError", "Number.prototype method called on incompatible receiver");
    if (std.mem.eql(u8, name, "valueOf")) return .{ .normal = .{ .number = n } }; // §21.1.3.26
    if (std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "toLocaleString")) {
        // §21.1.3.6 toString([radix]); §21.1.3.5 toLocaleString ≈ toString for the M-subset.
        var radix: i64 = 10;
        if (args.len > 0 and args[0] != .undefined and !std.mem.eql(u8, name, "toLocaleString")) {
            const rc = try it.toNumberV(args[0]);
            if (rc.isAbrupt()) return rc;
            radix = ops.numberToInt32(rc.normal.number);
        }
        if (radix < 2 or radix > 36) return it.throwError("RangeError", "toString() radix must be between 2 and 36");
        // §21.1.3.6: NaN → "NaN", ±Infinity → "Infinity"/"-Infinity" REGARDLESS of radix (the radix
        // digit-conversion only applies to finite values; routing non-finite to the base-10 path
        // produces the spec strings — `numberToRadixString` would otherwise emit garbage for them).
        if (radix == 10 or std.math.isNan(n) or std.math.isInf(n)) return .{ .normal = .{ .string = try it.toString(.{ .number = n }) } };
        return .{ .normal = .{ .string = try numberToRadixString(it.arena, n, @intCast(radix)) } };
    }
    if (std.mem.eql(u8, name, "toFixed")) return numberToFixed(it, n, args); // §21.1.3.3
    if (std.mem.eql(u8, name, "toExponential")) return numberToExponential(it, n, args); // §21.1.3.2
    if (std.mem.eql(u8, name, "toPrecision")) return numberToPrecision(it, n, args); // §21.1.3.5
    unreachable;
}

/// §21.1.3.3 Number.prototype.toFixed ( fractionDigits ).
fn numberToFixed(it: *Interpreter, n: f64, args: []const Value) EvalError!Completion {
    const fc = try it.toIntegerOrInfinity(if (args.len > 0) args[0] else .undefined);
    if (fc.isAbrupt()) return fc;
    const f = fc.normal.number;
    if (!(f >= 0 and f <= 100)) return it.throwError("RangeError", "toFixed() digits argument must be between 0 and 100");
    if (std.math.isNan(n)) return .{ .normal = .{ .string = "NaN" } };
    // §21.1.3.3 step 9: |x| ≥ 1e21 → ToString(x).
    if (@abs(n) >= 1e21) return .{ .normal = .{ .string = try it.toString(.{ .number = n }) } };
    const digits: usize = @intFromFloat(f);
    const s = try std.fmt.allocPrint(it.arena, "{d:.[1]}", .{ n, digits });
    return .{ .normal = .{ .string = s } };
}

/// §21.1.3.2 Number.prototype.toExponential ( fractionDigits ).
fn numberToExponential(it: *Interpreter, n: f64, args: []const Value) EvalError!Completion {
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    const undefined_digits = arg == .undefined;
    const fc = try it.toIntegerOrInfinity(arg);
    if (fc.isAbrupt()) return fc;
    const f = fc.normal.number;
    if (std.math.isNan(n)) return .{ .normal = .{ .string = "NaN" } };
    if (std.math.isInf(n)) return .{ .normal = .{ .string = if (n < 0) "-Infinity" else "Infinity" } };
    if (!undefined_digits and !(f >= 0 and f <= 100))
        return it.throwError("RangeError", "toExponential() argument must be between 0 and 100");
    const s = if (undefined_digits)
        try std.fmt.allocPrint(it.arena, "{e}", .{n})
    else
        try std.fmt.allocPrint(it.arena, "{e:.[1]}", .{ n, @as(usize, @intFromFloat(f)) });
    return .{ .normal = .{ .string = try canonicalizeExponent(it.arena, s) } };
}

/// §21.1.3.5 Number.prototype.toPrecision ( precision ).
fn numberToPrecision(it: *Interpreter, n: f64, args: []const Value) EvalError!Completion {
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    if (arg == .undefined) return .{ .normal = .{ .string = try it.toString(.{ .number = n }) } }; // §21.1.3.5 step 2
    const pc = try it.toIntegerOrInfinity(arg);
    if (pc.isAbrupt()) return pc;
    const p = pc.normal.number;
    if (std.math.isNan(n)) return .{ .normal = .{ .string = "NaN" } };
    if (std.math.isInf(n)) return .{ .normal = .{ .string = if (n < 0) "-Infinity" else "Infinity" } };
    if (!(p >= 1 and p <= 100)) return it.throwError("RangeError", "toPrecision() argument must be between 1 and 100");
    const prec: usize = @intFromFloat(p);
    if (n == 0) {
        // §21.1.3.5: zero formats as `0`, `0.0`, … with `precision` significant digits.
        if (prec == 1) return .{ .normal = .{ .string = "0" } };
        const z = try std.fmt.allocPrint(it.arena, "0.{s}", .{try repeatChar(it.arena, '0', prec - 1)});
        return .{ .normal = .{ .string = z } };
    }
    // Decide fixed vs exponential per the decimal exponent `e` (§21.1.3.5 steps 10–11).
    const e: i32 = @intFromFloat(@floor(std.math.log10(@abs(n))));
    if (e < -6 or e >= @as(i32, @intCast(prec))) {
        const s = try std.fmt.allocPrint(it.arena, "{e:.[1]}", .{ n, prec - 1 });
        return .{ .normal = .{ .string = try canonicalizeExponent(it.arena, s) } };
    }
    // Fixed-point with (prec - 1 - e) fractional digits (clamped at 0).
    const frac_i: i32 = @as(i32, @intCast(prec)) - 1 - e;
    const frac: usize = if (frac_i < 0) 0 else @intCast(frac_i);
    const s = try std.fmt.allocPrint(it.arena, "{d:.[1]}", .{ n, frac });
    return .{ .normal = .{ .string = s } };
}

fn repeatChar(arena: std.mem.Allocator, c: u8, count: usize) std.mem.Allocator.Error![]const u8 {
    const buf = try arena.alloc(u8, count);
    @memset(buf, c);
    return buf;
}

/// §6.1.6.1.20 Number::toString for radix 2..36 (≠10). NaN/±Inf already handled by the caller's radix-10
/// path; here `n` is finite. Emits an optional `-`, the integer part by repeated division, then up to
/// `frac_limit` fractional digits (the spec mandates "as many as needed to uniquely round-trip"; we use a
/// bounded expansion, matching V8 for the Test262 corpus). Trailing zeros are trimmed.
fn numberToRadixString(arena: std.mem.Allocator, n: f64, radix: u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var x = n;
    if (std.math.signbit(x)) {
        try out.append(arena, '-');
        x = -x;
    }
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    const rf: f64 = @floatFromInt(radix);
    // Integer part.
    var int_part = @floor(x);
    var frac = x - int_part;
    var int_buf: [1100]u8 = undefined; // f64 max ≈ 1.8e308; ~1075 base-2 digits suffice
    var ilen: usize = 0;
    if (int_part == 0) {
        int_buf[ilen] = '0';
        ilen += 1;
    } else {
        while (int_part >= 1 and ilen < int_buf.len) {
            const digit: usize = @intFromFloat(@mod(int_part, rf));
            int_buf[ilen] = digits[digit];
            ilen += 1;
            int_part = @floor(int_part / rf);
        }
    }
    // Emit integer digits reversed.
    var k: usize = ilen;
    while (k > 0) {
        k -= 1;
        try out.append(arena, int_buf[k]);
    }
    // Fractional part — bounded expansion, trailing zeros trimmed.
    if (frac > 0) {
        try out.append(arena, '.');
        const frac_limit: usize = 1100;
        var count: usize = 0;
        var frac_buf: std.ArrayList(u8) = .empty;
        while (frac > 0 and count < frac_limit) : (count += 1) {
            frac *= rf;
            const digit: usize = @intFromFloat(@floor(frac));
            try frac_buf.append(arena, digits[if (digit >= radix) radix - 1 else digit]);
            frac -= @floor(frac);
        }
        // Trim trailing zeros.
        var flen = frac_buf.items.len;
        while (flen > 0 and frac_buf.items[flen - 1] == '0') flen -= 1;
        try out.appendSlice(arena, frac_buf.items[0..flen]);
    }
    return out.items;
}

/// Normalize a Zig `{e}`-formatted Number into the ECMAScript form: collapse `e+05` → `e+5`,
/// `e-007` → `e-7` (strip leading zeros in the exponent), and ensure an explicit sign. Zig already
/// emits a sign; this only trims the exponent's leading zeros. Input is ASCII.
fn canonicalizeExponent(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    const e_idx = std.mem.indexOfScalar(u8, s, 'e') orelse return s;
    const mantissa = s[0..e_idx];
    var rest = s[e_idx + 1 ..];
    var sign: u8 = '+';
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        sign = rest[0];
        rest = rest[1..];
    }
    // Strip leading zeros (keep at least one digit).
    var d: usize = 0;
    while (d + 1 < rest.len and rest[d] == '0') d += 1;
    return std.fmt.allocPrint(arena, "{s}e{c}{s}", .{ mantissa, sign, rest[d..] });
}
