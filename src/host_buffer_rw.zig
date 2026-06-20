//! HOST runtime (Node axis, spec 103 — NOT ECMA-262): the Buffer numeric read/write matrix.
//! Split out of `host_buffer.zig` to keep that file under the size budget. Each `read*`/`write*`
//! method name maps to (byte width, signedness, little/big-endian, float?); reads return a JS
//! number, writes store the bytes and return `offset + width`. Bounds violations throw RangeError.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

/// Decoded shape of a `read*`/`write*` method name.
const Spec = struct {
    width: usize,
    signed: bool,
    little: bool,
    is_float: bool,
    /// Variable-width form (`readUIntLE`/`writeIntBE`/...): width comes from a `byteLength` argument
    /// (1–6) instead of the name. `width` is left 0 for these.
    variable: bool = false,
};

/// Parse a numeric accessor method name (after stripping the `read`/`write` prefix) into a `Spec`,
/// or null if `rest` is not a recognized numeric accessor. Examples of `rest`: "UInt8", "Int16LE",
/// "UInt32BE", "FloatLE", "DoubleBE".
fn parseSpec(rest: []const u8) ?Spec {
    const eq = std.mem.eql;
    if (eq(u8, rest, "Int8")) return .{ .width = 1, .signed = true, .little = false, .is_float = false };
    if (eq(u8, rest, "UInt8")) return .{ .width = 1, .signed = false, .little = false, .is_float = false };
    // Float / Double carry an endianness suffix.
    if (std.mem.startsWith(u8, rest, "Float")) {
        const e = rest[5..];
        if (eq(u8, e, "LE")) return .{ .width = 4, .signed = true, .little = true, .is_float = true };
        if (eq(u8, e, "BE")) return .{ .width = 4, .signed = true, .little = false, .is_float = true };
        return null;
    }
    if (std.mem.startsWith(u8, rest, "Double")) {
        const e = rest[6..];
        if (eq(u8, e, "LE")) return .{ .width = 8, .signed = true, .little = true, .is_float = true };
        if (eq(u8, e, "BE")) return .{ .width = 8, .signed = true, .little = false, .is_float = true };
        return null;
    }
    // Integer forms: (U)Int{16,32}{LE,BE}.
    var r = rest;
    var signed = true;
    if (std.mem.startsWith(u8, r, "U")) {
        signed = false;
        r = r[1..];
    }
    if (!std.mem.startsWith(u8, r, "Int")) return null;
    r = r[3..];
    var width: usize = 0;
    var variable = false;
    if (std.mem.startsWith(u8, r, "16")) {
        width = 2;
        r = r[2..];
    } else if (std.mem.startsWith(u8, r, "32")) {
        width = 4;
        r = r[2..];
    } else {
        // Variable-width: `readIntLE` / `writeUIntBE` etc. — width = a byteLength arg (1–6).
        variable = true;
    }
    if (eq(u8, r, "LE")) return .{ .width = width, .signed = signed, .little = true, .is_float = false, .variable = variable };
    if (eq(u8, r, "BE")) return .{ .width = width, .signed = signed, .little = false, .is_float = false, .variable = variable };
    return null;
}

/// Read `width` bytes at `bytes[off..]` as an unsigned integer with the given endianness.
fn readUnsigned(bytes: []const u8, off: usize, width: usize, little: bool) u64 {
    var v: u64 = 0;
    if (little) {
        var k: usize = width;
        while (k > 0) {
            k -= 1;
            v = (v << 8) | bytes[off + k];
        }
    } else {
        var k: usize = 0;
        while (k < width) : (k += 1) v = (v << 8) | bytes[off + k];
    }
    return v;
}

/// Store the low `width` bytes of `v` at `bytes[off..]` with the given endianness.
fn writeUnsigned(bytes: []u8, off: usize, width: usize, little: bool, v: u64) void {
    if (little) {
        var k: usize = 0;
        while (k < width) : (k += 1) bytes[off + k] = @truncate(v >> @intCast(8 * k));
    } else {
        var k: usize = 0;
        while (k < width) : (k += 1) bytes[off + k] = @truncate(v >> @intCast(8 * (width - 1 - k)));
    }
}

/// Sign-extend an unsigned `width`-byte value to an i64 (two's complement).
fn signExtend(u: u64, width: usize) i64 {
    const bits: u6 = @intCast(width * 8);
    if (bits == 64) return @bitCast(u);
    const sign_bit: u64 = @as(u64, 1) << @intCast(bits - 1);
    if (u & sign_bit != 0) {
        const ext: u64 = ~((@as(u64, 1) << bits) - 1);
        return @bitCast(u | ext);
    }
    return @bitCast(u);
}

/// Dispatch a `read*`/`write*` numeric accessor named `name` on `bytes`. Returns null completion
/// (via the `?` ) when `name` is not a numeric accessor so the caller can fall through.
pub fn readWrite(self: *Interpreter, bytes: []u8, name: []const u8, args: []const Value) EvalError!?Completion {
    const is_read = std.mem.startsWith(u8, name, "read");
    const is_write = std.mem.startsWith(u8, name, "write");
    if (!is_read and !is_write) return null;
    const rest = name[if (is_read) 4 else 5..];
    // BigInt 64-bit accessors are handled separately (their values are BigInts, not numbers).
    if (std.mem.startsWith(u8, rest, "Big")) return try bigAccessor(self, bytes, rest[3..], is_read, args);
    var spec = parseSpec(rest) orelse return null;

    // Variable-width (read/writeUIntLE etc.): the width is a trailing `byteLength` argument (1–6).
    // read: (offset, byteLength); write: (value, offset, byteLength).
    if (spec.variable) {
        const bl_arg: Value = if (is_read) (if (args.len > 1) args[1] else .undefined) else (if (args.len > 2) args[2] else .undefined);
        const bl = switch (try validateByteLength(self, bl_arg)) {
            .v => |w| w,
            .throw => |c| return c,
        };
        spec.width = bl;
    }

    if (is_read) {
        const off = switch (try validateOffset(self, if (args.len > 0) args[0] else .undefined, bytes.len, spec.width, !spec.variable)) {
            .v => |o| o,
            .throw => |c| return c,
        };
        const num: f64 = if (spec.is_float) blk: {
            if (spec.width == 4) {
                const bits: u32 = @truncate(readUnsigned(bytes, off, 4, spec.little));
                break :blk @as(f64, @as(f32, @bitCast(bits)));
            } else {
                const bits: u64 = readUnsigned(bytes, off, 8, spec.little);
                break :blk @as(f64, @bitCast(bits));
            }
        } else blk: {
            const u = readUnsigned(bytes, off, spec.width, spec.little);
            break :blk if (spec.signed) @as(f64, @floatFromInt(signExtend(u, spec.width))) else @as(f64, @floatFromInt(u));
        };
        return .{ .normal = .{ .number = num } };
    }

    // write*: value = args[0], offset = args[1].
    const nd = try self.toNumberV(if (args.len > 0) args[0] else .undefined);
    if (nd.isAbrupt()) return nd;
    const off = switch (try validateOffset(self, if (args.len > 1) args[1] else .undefined, bytes.len, spec.width, !spec.variable)) {
        .v => |o| o,
        .throw => |c| return c,
    };
    const x = nd.normal.number;
    if (spec.is_float) {
        if (spec.width == 4) {
            const bits: u32 = @bitCast(@as(f32, @floatCast(x)));
            writeUnsigned(bytes, off, 4, spec.little, bits);
        } else {
            const bits: u64 = @bitCast(x);
            writeUnsigned(bytes, off, 8, spec.little, bits);
        }
    } else {
        // Integer write: the value must be within the type's representable range (Node throws
        // ERR_OUT_OF_RANGE otherwise) — no silent wrap.
        const bits: usize = spec.width * 8;
        const bits_f: f64 = @floatFromInt(bits);
        const max: f64 = if (spec.signed) std.math.pow(f64, 2, bits_f - 1) - 1 else std.math.pow(f64, 2, bits_f) - 1;
        const min: f64 = if (spec.signed) -std.math.pow(f64, 2, bits_f - 1) else 0;
        if (std.math.isNan(x) or x < min or x > max) {
            // For widths > 4 bytes, Node prints the bounds as `2 ** N` exponent notation (the values
            // exceed safe-integer-friendly display); otherwise it prints the literal min/max.
            const range = if (spec.width > 4) blk: {
                const exp = bits - 1;
                break :blk if (spec.signed)
                    std.fmt.allocPrint(self.arena, ">= -(2 ** {d}) and < 2 ** {d}", .{ exp, exp }) catch return error.OutOfMemory
                else
                    std.fmt.allocPrint(self.arena, ">= 0 and < 2 ** {d}", .{bits}) catch return error.OutOfMemory;
            } else std.fmt.allocPrint(self.arena, ">= {s} and <= {s}", .{ try fmtBound(self, min), try fmtBound(self, max) }) catch return error.OutOfMemory;
            const prefix = std.fmt.allocPrint(self.arena, "The value of \"value\" is out of range. It must be {s}. Received ", .{range}) catch return error.OutOfMemory;
            return try rangeCode(self, try fmtReceived(self, prefix, x));
        }
        const t = @trunc(x);
        const modulus: f64 = std.math.pow(f64, 2.0, bits_f);
        var tt = t;
        if (tt < 0) tt += modulus;
        const u: u64 = @intFromFloat(tt);
        writeUnsigned(bytes, off, spec.width, spec.little, u);
    }
    return .{ .normal = .{ .number = @floatFromInt(off + spec.width) } };
}

/// Format an integer bound (min/max) for the value-range error message. Bounds ≥ 2^32 (abs) get
/// Node's `_` separators.
fn fmtBound(self: *Interpreter, n: f64) EvalError![]const u8 {
    const ao = @import("abstract_ops.zig");
    const s = ao.numberToString(self.arena, n) catch return error.OutOfMemory;
    if (@abs(n) > 4294967296) return addSeparators(self.arena, s) catch return error.OutOfMemory;
    return s;
}

/// A validation result: a usize value or a thrown completion to propagate.
const ValOrThrow = union(enum) { v: usize, throw: Completion };

/// BigInt 64-bit read/write. `rest` is the suffix after "Big" (e.g. "Int64LE", "UInt64BE").
/// read: (offset) → BigInt; write: (value:BigInt, offset) → offset+8.
fn bigAccessor(self: *Interpreter, bytes: []u8, rest: []const u8, is_read: bool, args: []const Value) EvalError!?Completion {
    const eq = std.mem.eql;
    var r = rest;
    var signed = true;
    if (std.mem.startsWith(u8, r, "U")) {
        signed = false;
        r = r[1..];
    }
    if (!std.mem.startsWith(u8, r, "Int64")) return null;
    r = r[5..];
    const little = if (eq(u8, r, "LE")) true else if (eq(u8, r, "BE")) false else return null;
    const bigint = @import("bigint.zig");

    if (is_read) {
        const off = switch (try validateOffset(self, if (args.len > 0) args[0] else .undefined, bytes.len, 8, true)) {
            .v => |o| o,
            .throw => |c| return c,
        };
        const u = readUnsigned(bytes, off, 8, little);
        const big = if (signed)
            bigint.fromI64(self.arena, @bitCast(u)) catch return error.OutOfMemory
        else
            bigint.fromU64(self.arena, u) catch return error.OutOfMemory;
        return .{ .normal = .{ .bigint = big } };
    }

    // write: value (must be a BigInt) then offset.
    const val_v: Value = if (args.len > 0) args[0] else .undefined;
    if (val_v != .bigint)
        return try throwBigType(self);
    // Range check: signed must fit i64, unsigned must fit u64.
    const fits = if (signed) (val_v.bigint.toInt(i64) catch null) != null else (val_v.bigint.toInt(u64) catch null) != null;
    if (!fits)
        return try rangeCode(self, "The value of \"value\" is out of range.");
    const u: u64 = if (signed)
        @bitCast(val_v.bigint.toInt(i64) catch 0)
    else
        (val_v.bigint.toInt(u64) catch 0);
    const off = switch (try validateOffset(self, if (args.len > 1) args[1] else .undefined, bytes.len, 8, true)) {
        .v => |o| o,
        .throw => |c| return c,
    };
    writeUnsigned(bytes, off, 8, little, u);
    return .{ .normal = .{ .number = @floatFromInt(off + 8) } };
}

fn throwBigType(self: *Interpreter) EvalError!Completion {
    const object_mod = @import("object.zig");
    const Object = object_mod.Object;
    const err = try Object.create(self.arena, self.errorProto("TypeError"));
    err.error_data = true;
    try err.set("name", .{ .string = "TypeError" });
    try err.set("message", .{ .string = "The \"value\" argument must be of type bigint." });
    try err.defineData("code", .{ .string = "ERR_INVALID_ARG_TYPE" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Throw a RangeError carrying `code` (Node's tests' `assert.throws({ code })` validators read it).
fn rangeCode(self: *Interpreter, msg: []const u8) EvalError!Completion {
    const object_mod = @import("object.zig");
    const Object = object_mod.Object;
    const err = try Object.create(self.arena, self.errorProto("RangeError"));
    err.error_data = true;
    try err.set("name", .{ .string = "RangeError" });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = "ERR_OUT_OF_RANGE" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Validate a read/write `offset`: must be a number (Node throws ERR_INVALID_ARG_TYPE for any other
/// type), a non-negative integer, and leave room for `width` bytes (ERR_OUT_OF_RANGE otherwise).
/// `undefined` → 0.
fn validateOffset(self: *Interpreter, v: Value, len: usize, width: usize, allow_undefined: bool) EvalError!ValOrThrow {
    if (v == .undefined) {
        // Fixed-width accessors default a missing offset to 0; variable-width require it (TypeError).
        if (!allow_undefined) return .{ .throw = try argTypeErr(self, "offset") };
        if (width > len) return .{ .throw = try bufBounds(self) };
        return .{ .v = 0 };
    }
    // Node's `validateNumber` rejects non-number offsets with ERR_INVALID_ARG_TYPE.
    if (v != .number) return .{ .throw = try argTypeErr(self, "offset") };
    const n = v.number;
    if (std.math.isNan(n) or n != @trunc(n))
        return .{ .throw = try rangeCode(self, try fmtReceived(self, "The value of \"offset\" is out of range. It must be an integer. Received ", n)) };
    // The buffer can't even hold `width` bytes → ERR_BUFFER_OUT_OF_BOUNDS.
    if (width > len) return .{ .throw = try bufBounds(self) };
    // Valid range is [0, len - width]; outside → ERR_OUT_OF_RANGE with the explicit bounds.
    const max: f64 = @floatFromInt(len - width);
    if (n < 0 or n > max) {
        const prefix = std.fmt.allocPrint(self.arena, "The value of \"offset\" is out of range. It must be >= 0 and <= {d}. Received ", .{len - width}) catch return error.OutOfMemory;
        return .{ .throw = try rangeCode(self, try fmtReceived(self, prefix, n)) };
    }
    return .{ .v = @intFromFloat(n) };
}

/// Throw ERR_BUFFER_OUT_OF_BOUNDS (the buffer is too small for the access width).
fn bufBounds(self: *Interpreter) EvalError!Completion {
    const object_mod = @import("object.zig");
    const Object = object_mod.Object;
    const err = try Object.create(self.arena, self.errorProto("RangeError"));
    err.error_data = true;
    try err.set("name", .{ .string = "RangeError" });
    try err.set("message", .{ .string = "Attempt to access memory outside buffer bounds" });
    try err.defineData("code", .{ .string = "ERR_BUFFER_OUT_OF_BOUNDS" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Append a Node-formatted "Received <n>" value to `prefix`. Node's ERR_OUT_OF_RANGE formatter only
/// inserts `_` thousands separators for integers whose absolute value is ≥ 2^32; otherwise it uses
/// the plain JS number string.
fn fmtReceived(self: *Interpreter, prefix: []const u8, n: f64) EvalError![]const u8 {
    const ao = @import("abstract_ops.zig");
    const num = ao.numberToString(self.arena, n) catch return error.OutOfMemory;
    const formatted = if (n == @trunc(n) and !std.math.isNan(n) and !std.math.isInf(n) and @abs(n) > 4294967296)
        (addSeparators(self.arena, num) catch return error.OutOfMemory)
    else
        num;
    return std.fmt.allocPrint(self.arena, "{s}{s}", .{ prefix, formatted }) catch return error.OutOfMemory;
}

/// Insert `_` thousands separators into a decimal integer string (Node's `addNumericSeparator`).
fn addSeparators(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const neg = s.len > 0 and s[0] == '-';
    const digits = if (neg) s[1..] else s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try out.append(arena, '-');
    var i: usize = 0;
    while (i < digits.len) : (i += 1) {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(arena, '_');
        try out.append(arena, digits[i]);
    }
    return out.items;
}

/// Throw a TypeError with code ERR_INVALID_ARG_TYPE for a wrong-typed `argName`.
fn argTypeErr(self: *Interpreter, arg_name: []const u8) EvalError!Completion {
    const object_mod = @import("object.zig");
    const Object = object_mod.Object;
    const msg = std.fmt.allocPrint(self.arena, "The \"{s}\" argument must be of type number.", .{arg_name}) catch return error.OutOfMemory;
    const err = try Object.create(self.arena, self.errorProto("TypeError"));
    err.error_data = true;
    try err.set("name", .{ .string = "TypeError" });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = "ERR_INVALID_ARG_TYPE" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Validate a variable-width `byteLength` (1–6), per Node's read/writeUIntLE family.
fn validateByteLength(self: *Interpreter, v: Value) EvalError!ValOrThrow {
    if (v != .number) return .{ .throw = try argTypeErr(self, "byteLength") };
    const n = v.number;
    if (std.math.isNan(n) or n != @trunc(n))
        return .{ .throw = try rangeCode(self, try fmtReceived(self, "The value of \"byteLength\" is out of range. It must be an integer. Received ", n)) };
    if (n < 1 or n > 6)
        return .{ .throw = try rangeCode(self, try fmtReceived(self, "The value of \"byteLength\" is out of range. It must be >= 1 and <= 6. Received ", n)) };
    return .{ .v = @intFromFloat(n) };
}
