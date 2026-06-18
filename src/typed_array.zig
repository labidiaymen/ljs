//! §23.2 / §25.1 / §25.3 Typed-array element model (Phase 1 foundation). Defines `ElemType` (the 11
//! TypedArray element types), its per-type metadata (`bytesPerElement`, `contentType`), and the pure
//! element codecs (`getElement` / `setElement`) that read/write a typed value into a byte buffer.
//!
//! TypedArray element access uses PLATFORM-NATIVE endianness (§23.2.5.13 GetValueFromBuffer / §23.2.5.15
//! SetValueInBuffer with isTypedArray=true): the bytes are written in the host's native order and read
//! back the same way, so a same-machine round-trip is order-independent. (DataView, which honors an
//! explicit `littleEndian` flag, is implemented separately in Phase 2 and may reuse these helpers with a
//! byte-swap.) The codecs are pure and own no state, so the TypedArray and DataView surfaces (Phase 2)
//! share them.
const std = @import("std");
const Value = @import("value.zig").Value;
const bigint = @import("bigint.zig");

/// §23.2 Table 70 — the element type of a concrete TypedArray. `u8_clamped` is the
/// `Uint8ClampedArray` element type (write clamps to [0,255] instead of wrapping). `i64`/`u64` back
/// `BigInt64Array`/`BigUint64Array` (content type bigint); the other nine are content type number.
pub const ElemType = enum {
    i8,
    u8,
    u8_clamped,
    i16,
    u16,
    i32,
    u32,
    f32,
    f64,
    i64,
    u64,

    /// §23.2 Table 70 [[ContentType]] — `bigint` for the 64-bit-integer element types, else `number`.
    /// A write to a bigint element requires a BigInt value (ToBigInt); a write to a number element
    /// requires a Number (ToNumber). Mixing the two is a TypeError (enforced by the caller).
    pub const ContentType = enum { number, bigint };

    /// §23.2 Table 70 [[ContentType]] of this element type.
    pub fn contentType(self: ElemType) ContentType {
        return switch (self) {
            .i64, .u64 => .bigint,
            else => .number,
        };
    }

    /// §23.2 Table 70 — the byte size of one element of this type (Int8/Uint8/Uint8Clamped → 1,
    /// Int16/Uint16 → 2, Int32/Uint32/Float32 → 4, Float64/BigInt64/BigUint64 → 8).
    pub fn bytesPerElement(self: ElemType) usize {
        return switch (self) {
            .i8, .u8, .u8_clamped => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64, .i64, .u64 => 8,
        };
    }

    /// §23.2.7 the constructor name for this element type (`"Int8Array"`, …). Used by Phase 2 for the
    /// per-constructor `[Symbol.toStringTag]` and `name`.
    pub fn constructorName(self: ElemType) []const u8 {
        return switch (self) {
            .i8 => "Int8Array",
            .u8 => "Uint8Array",
            .u8_clamped => "Uint8ClampedArray",
            .i16 => "Int16Array",
            .u16 => "Uint16Array",
            .i32 => "Int32Array",
            .u32 => "Uint32Array",
            .f32 => "Float32Array",
            .f64 => "Float64Array",
            .i64 => "BigInt64Array",
            .u64 => "BigUint64Array",
        };
    }
};

/// §23.2.5.13 GetValueFromBuffer (isTypedArray = true ⇒ native endianness). Read the element at logical
/// `index` (an element count, NOT a byte offset) from `bytes`, returning the JS Value: a Number for the
/// nine numeric types, a BigInt (allocated in `arena`) for `i64`/`u64`. The caller guarantees the slice
/// is in bounds: `bytes.len >= (index + 1) * bytesPerElement(elem)`.
pub fn getElement(elem: ElemType, bytes: []const u8, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
    const bpe = elem.bytesPerElement();
    const off = index * bpe;
    const raw = bytes[off .. off + bpe];
    return switch (elem) {
        .i8 => .{ .number = @floatFromInt(@as(i8, @bitCast(raw[0]))) },
        .u8, .u8_clamped => .{ .number = @floatFromInt(raw[0]) },
        .i16 => .{ .number = @floatFromInt(readInt(i16, raw)) },
        .u16 => .{ .number = @floatFromInt(readInt(u16, raw)) },
        .i32 => .{ .number = @floatFromInt(readInt(i32, raw)) },
        .u32 => .{ .number = @floatFromInt(readInt(u32, raw)) },
        .f32 => .{ .number = floatFromBits(f32, readInt(u32, raw)) },
        .f64 => .{ .number = floatFromBits(f64, readInt(u64, raw)) },
        .i64 => .{ .bigint = bigint.fromI64(arena, readInt(i64, raw)) catch return error.OutOfMemory },
        .u64 => .{ .bigint = try u64ToBigInt(arena, readInt(u64, raw)) },
    };
}

/// §23.2.5.15 SetValueInBuffer (isTypedArray = true ⇒ native endianness). Write a value into the element
/// at logical `index` of `bytes`. For the nine numeric types `num` carries the already-ToNumber'd value
/// (§23.2.5.1 step 11 conversions: ToInt8/ToUint8/ToUint8Clamp/…/the float identity). For `i64`/`u64`,
/// `num` is unused and `big` carries the already-ToBigInt'd value (modulo 2^64). The caller guarantees
/// the slice is in bounds and supplies the correctly-typed argument for the element's content type.
pub fn setElement(elem: ElemType, bytes: []u8, index: usize, num: f64, big: ?*const std.math.big.int.Const) std.mem.Allocator.Error!void {
    const bpe = elem.bytesPerElement();
    const off = index * bpe;
    const dst = bytes[off .. off + bpe];
    switch (elem) {
        .i8 => dst[0] = @bitCast(toInt(i8, num)),
        .u8 => dst[0] = toInt(u8, num),
        .u8_clamped => dst[0] = toUint8Clamp(num),
        .i16 => writeInt(i16, dst, toInt(i16, num)),
        .u16 => writeInt(u16, dst, toInt(u16, num)),
        .i32 => writeInt(i32, dst, toInt(i32, num)),
        .u32 => writeInt(u32, dst, toInt(u32, num)),
        .f32 => writeInt(u32, dst, @bitCast(@as(f32, @floatCast(num)))),
        .f64 => writeInt(u64, dst, @bitCast(num)),
        // §23.2.5.1.2/.3 ToBigInt64 / ToBigUint64 — wrap to 64 bits (modulo 2^64); the bit pattern is
        // identical for signed/unsigned (two's complement), so one truncation suffices.
        .i64, .u64 => writeInt(u64, dst, try bigIntToU64Bits(big.?)),
    }
}

// ── internal numeric helpers ────────────────────────────────────────────────

/// Read an integer of type `Int` from `raw` (exactly @sizeOf(Int) bytes) in NATIVE byte order.
fn readInt(comptime Int: type, raw: []const u8) Int {
    return std.mem.bytesToValue(Int, raw[0..@sizeOf(Int)]);
}

/// Write an integer of type `Int` into `dst` (exactly @sizeOf(Int) bytes) in NATIVE byte order.
fn writeInt(comptime Int: type, dst: []u8, v: Int) void {
    const b = std.mem.toBytes(v);
    @memcpy(dst[0..@sizeOf(Int)], &b);
}

/// Reinterpret the integer bit pattern `bits` as the float type `Float` (the IEEE-754 decode).
fn floatFromBits(comptime Float: type, bits: anytype) f64 {
    return @as(f64, @as(Float, @bitCast(bits)));
}

/// §7.1.* ToInt8/ToUint8/ToInt16/… — the modular conversion for a finite, already-ToNumber'd value.
/// NaN/±Inf map to 0; otherwise truncate toward zero then take the low bits (two's complement wrap),
/// matching `ℝ(ToNumber(v)) modulo 2^bits` reinterpreted per `Int`'s signedness.
fn toInt(comptime Int: type, num: f64) Int {
    if (!std.math.isFinite(num)) return 0;
    // truncate toward zero, then wrap into the integer's modular range
    const t = @trunc(num);
    const bits = @typeInfo(Int).int.bits;
    const Wide = std.meta.Int(.unsigned, 64);
    const modulus: f64 = std.math.pow(f64, 2, @floatFromInt(bits));
    // r in [0, 2^bits): the canonical residue of t.
    var r = @mod(t, modulus);
    if (r < 0) r += modulus;
    const u: Wide = @intFromFloat(r);
    const Unsigned = std.meta.Int(.unsigned, bits);
    const low: Unsigned = @truncate(u);
    return @bitCast(low);
}

/// §7.1.11 ToUint8Clamp — round-half-to-even into [0, 255]; NaN → 0, <0 → 0, >255 → 255.
fn toUint8Clamp(num: f64) u8 {
    if (std.math.isNan(num)) return 0;
    if (num <= 0) return 0;
    if (num >= 255) return 255;
    // round half to even
    const f = @floor(num);
    const frac = num - f;
    var r: f64 = f;
    if (frac > 0.5) {
        r = f + 1;
    } else if (frac == 0.5) {
        // round to even
        r = if (@mod(f, 2) == 0) f else f + 1;
    }
    return @intFromFloat(r);
}

/// A BigInt holding the (non-negative) value of a raw `u64` — used by `getElement` for `u64`.
fn u64ToBigInt(arena: std.mem.Allocator, v: u64) std.mem.Allocator.Error!*const std.math.big.int.Const {
    // bigint.fromI64 takes an i64; for values that fit in i63 this is exact, but a high-bit-set u64
    // must be built explicitly. Reinterpret as signed, then asUintN(64) recovers the magnitude.
    if (v <= std.math.maxInt(i64)) return bigint.fromI64(arena, @intCast(v)) catch error.OutOfMemory;
    const signed = bigint.fromI64(arena, @as(i64, @bitCast(v))) catch return error.OutOfMemory;
    return bigint.asUintN(arena, 64, signed) catch error.OutOfMemory;
}

/// §23.2.5.1.2/.3 — the low 64 bits of a BigInt (modulo 2^64), as a `u64` bit pattern. For
/// BigInt64Array this u64 is the two's-complement encoding of the wrapped signed value; for
/// BigUint64Array it is the wrapped unsigned value. (Same bits either way — only interpretation differs.)
fn bigIntToU64Bits(v: *const std.math.big.int.Const) std.mem.Allocator.Error!u64 {
    // Wrap to an unsigned 64-bit residue, then extract the magnitude (now guaranteed to fit in u64).
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const wrapped = bigint.asUintN(scratch.allocator(), 64, v) catch return error.OutOfMemory;
    return wrapped.toInt(u64) catch 0;
}

test "ElemType metadata" {
    try std.testing.expectEqual(@as(usize, 1), ElemType.u8.bytesPerElement());
    try std.testing.expectEqual(@as(usize, 8), ElemType.f64.bytesPerElement());
    try std.testing.expectEqual(ElemType.ContentType.bigint, ElemType.i64.contentType());
    try std.testing.expectEqual(ElemType.ContentType.number, ElemType.u8.contentType());
}

test "uint8 wraparound + clamp" {
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    try setElement(.u8, &bytes, 1, 256, null);
    try std.testing.expectEqual(@as(u8, 0), bytes[1]);
    try setElement(.u8, &bytes, 0, 255, null);
    try std.testing.expectEqual(@as(u8, 255), bytes[0]);
    try setElement(.u8_clamped, &bytes, 2, 300, null);
    try std.testing.expectEqual(@as(u8, 255), bytes[2]);
    try setElement(.u8_clamped, &bytes, 3, -5, null);
    try std.testing.expectEqual(@as(u8, 0), bytes[3]);
}
