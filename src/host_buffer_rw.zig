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
    if (std.mem.startsWith(u8, r, "16")) {
        width = 2;
        r = r[2..];
    } else if (std.mem.startsWith(u8, r, "32")) {
        width = 4;
        r = r[2..];
    } else return null;
    if (eq(u8, r, "LE")) return .{ .width = width, .signed = signed, .little = true, .is_float = false };
    if (eq(u8, r, "BE")) return .{ .width = width, .signed = signed, .little = false, .is_float = false };
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
    const spec = parseSpec(rest) orelse return null;

    if (is_read) {
        const off = try argOffset(self, if (args.len > 0) args[0] else .undefined, bytes.len);
        if (off + spec.width > bytes.len) return try rangeErr(self);
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
    const off = try argOffset(self, if (args.len > 1) args[1] else .undefined, bytes.len);
    if (off + spec.width > bytes.len) return try rangeErr(self);
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
        // Coerce to an integer modulo 2^(8*width); two's-complement wrapping handles signed too.
        const modulus: f64 = std.math.pow(f64, 2.0, @floatFromInt(spec.width * 8));
        var t = if (std.math.isNan(x)) 0.0 else @trunc(x);
        t = @mod(t, modulus);
        if (t < 0) t += modulus;
        const u: u64 = @intFromFloat(t);
        writeUnsigned(bytes, off, spec.width, spec.little, u);
    }
    return .{ .normal = .{ .number = @floatFromInt(off + spec.width) } };
}

fn rangeErr(self: *Interpreter) EvalError!Completion {
    return self.throwError("RangeError", "out of range");
}

/// Coerce an offset argument to a usize clamped to [0, max] (NaN/negative → 0).
fn argOffset(self: *Interpreter, v: Value, max: usize) EvalError!usize {
    if (v == .undefined) return 0;
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return 0;
    var n = nd.normal.number;
    if (std.math.isNan(n) or n < 0) n = 0;
    if (n > @as(f64, @floatFromInt(max))) n = @floatFromInt(max);
    return @intFromFloat(n);
}
