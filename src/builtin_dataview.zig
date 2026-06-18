//! §25.3 DataView — Phase 2-C of spec 083. A DataView is an exotic VIEW over an ArrayBuffer that
//! reads/writes multi-byte numeric values at an ARBITRARY byte offset with EXPLICIT endianness (unlike
//! a TypedArray, which indexes by element and uses platform-native order). This file implements:
//!   • `new DataView(buffer, byteOffset = 0, byteLength = buffer.byteLength - byteOffset)` (§25.3.2)
//!   • the `buffer` / `byteLength` / `byteOffset` getters + `[Symbol.toStringTag] = "DataView"` (§25.3.4)
//!   • `getInt8/Uint8/Int16/Uint16/Int32/Uint32/Float32/Float64/BigInt64/BigUint64` + matching `setXxx`,
//!     each honouring a `littleEndian` flag (default BIG-endian) (§25.3.4.5–.24).
//!
//! Endianness: rather than reuse the native-order `typed_array.zig` codecs (which would need a byte-swap),
//! this file reads/writes the backing bytes directly via `std.mem.readInt`/`writeInt` with an explicit
//! `std.builtin.Endian`, and `@bitCast` for the floats. The bytes live at
//! `dv.buffer.array_buffer.?.bytes[dv.byte_offset + requestIndex ..][0..elementSize]`.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const bigint = @import("bigint.zig");
const builtin_bigint = @import("builtin_bigint.zig");
const abstract_ops = @import("abstract_ops.zig");
const tarray = @import("typed_array.zig");

/// §25.3 GetViewByteLength — the LIVE byte length of a DataView, computed from the (possibly resized)
/// backing buffer. Tracking views (resizable buffer, no explicit length) follow the live buffer; fixed
/// views clamp the stored `byte_length` to what the live bytes hold (crash-safe). `bpe` is 1 (bytes).
fn liveByteLength(dv: object_mod.DataViewData, buffer_byte_len: usize) usize {
    return tarray.liveLength(dv.tracks_length, dv.byte_length, dv.byte_offset, buffer_byte_len, 1);
}

/// %DataView.prototype% — the [[Prototype]] of every DataView instance. Null in a realm-less eval.
fn dataViewProto(it: *Interpreter) ?*Object {
    return it.globalProto("DataView");
}

// ── construction ─────────────────────────────────────────────────────────────

/// §25.3.2.1 `new DataView(buffer, byteOffset = 0, byteLength)` — [[Construct]]. `this_val` is the
/// pre-created instance (proto-linked to new_target.prototype) handed in by `constructNT`. Validate:
///   1. `buffer` must be an ArrayBuffer (TypeError otherwise).
///   2. `offset = ToIndex(byteOffset)`; detach check; `offset > bufferByteLength` → RangeError.
///   3. `byteLength` undefined ⇒ view to end; else `viewByteLength = ToIndex(byteLength)` and
///      `offset + viewByteLength > bufferByteLength` → RangeError.
/// Then flip `this_val` into a `data_view` exotic over that slice. A plain call (no `new`) is a
/// TypeError, handled by the caller in `callNative`.
pub fn construct(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const buffer_arg: Value = if (args.len > 0) args[0] else .undefined;
    // §25.3.2.1 step 2: RequireInternalSlot(buffer, [[ArrayBufferData]]).
    if (buffer_arg != .object or buffer_arg.object.kind != .array_buffer) {
        return it.throwError("TypeError", "DataView constructor requires an ArrayBuffer");
    }
    const buffer = buffer_arg.object;

    // §25.3.2.1 step 3: offset = ToIndex(byteOffset).
    const offset_arg: Value = if (args.len > 1) args[1] else .undefined;
    const oc = try toIndex(it, offset_arg);
    if (oc.isAbrupt()) return oc;
    const offset: usize = @intFromFloat(oc.normal.number);

    // §25.3.2.1 step 4: IsDetachedBuffer check (ToIndex above is observable, so this is ordered after).
    const ab = buffer.array_buffer.?;
    if (ab.detached) return it.throwError("TypeError", "Cannot construct DataView on a detached ArrayBuffer");

    // §25.3.2.1 step 5: bufferByteLength.
    const buffer_byte_length = ab.bytes.len;
    // §25.3.2.1 step 6: offset > bufferByteLength → RangeError.
    if (offset > buffer_byte_length) {
        return it.throwError("RangeError", "DataView byteOffset is out of bounds");
    }

    // §25.3.2.1 steps 7–9: byteLength. undefined ⇒ view spans to the end of the buffer; otherwise
    // ToIndex it and reject an out-of-bounds end.
    const length_arg: Value = if (args.len > 2) args[2] else .undefined;
    const view_byte_length: usize = if (length_arg == .undefined)
        buffer_byte_length - offset
    else blk: {
        const lc = try toIndex(it, length_arg);
        if (lc.isAbrupt()) return lc;
        const vbl: usize = @intFromFloat(lc.normal.number);
        // §25.3.2.1 step 9.b: offset + viewByteLength > bufferByteLength → RangeError.
        if (offset + vbl > buffer_byte_length) {
            return it.throwError("RangeError", "DataView byteLength is out of bounds");
        }
        break :blk vbl;
    };

    // §25.3.2.1 steps 10–14: build the exotic on the pre-created instance (subclassing-safe — the
    // instance already carries new_target.prototype). A re-check of detachment is unnecessary: no user
    // code ran between the check above and here.
    // §25.3 a DataView over a RESIZABLE buffer with NO explicit byteLength tracks the live buffer.
    const tracks = (length_arg == .undefined) and (ab.max_byte_length != null);
    const obj: *Object = if (this_val == .object) this_val.object else try Object.create(it.arena, dataViewProto(it));
    obj.kind = .data_view;
    obj.data_view = .{ .buffer = buffer, .byte_offset = offset, .byte_length = view_byte_length, .tracks_length = tracks };
    return .{ .normal = .{ .object = obj } };
}

// ── getters ──────────────────────────────────────────────────────────────────

/// §25.3.4.1–.3 get DataView.prototype.{buffer,byteLength,byteOffset}. The receiver must be a DataView,
/// else TypeError (RequireInternalSlot). A detached buffer makes `byteLength`/`byteOffset` throw a
/// TypeError (§25.3.4.2/.3 step 5–6); `buffer` always returns the (possibly detached) viewed buffer.
pub fn getter(it: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .data_view) {
        return it.throwError("TypeError", "DataView.prototype getter called on a non-DataView");
    }
    const dv = this_val.object.data_view.?;
    if (std.mem.eql(u8, name, "buffer")) {
        // §25.3.4.1 — always returns the viewed buffer (no detach check).
        return .{ .normal = .{ .object = dv.buffer } };
    }
    const detached = dv.buffer.array_buffer.?.detached;
    if (std.mem.eql(u8, name, "byteLength")) {
        // §25.3.4.2 step 6: a detached buffer → TypeError.
        if (detached) return it.throwError("TypeError", "Cannot read byteLength of a DataView on a detached buffer");
        // §25.3.4.2 — the LIVE byte length (a tracking view follows the resized buffer).
        return .{ .normal = .{ .number = @floatFromInt(liveByteLength(dv, dv.buffer.array_buffer.?.bytes.len)) } };
    }
    if (std.mem.eql(u8, name, "byteOffset")) {
        // §25.3.4.3 step 6: a detached buffer → TypeError.
        if (detached) return it.throwError("TypeError", "Cannot read byteOffset of a DataView on a detached buffer");
        return .{ .normal = .{ .number = @floatFromInt(dv.byte_offset) } };
    }
    return .{ .normal = .undefined };
}

// ── get/set methods ──────────────────────────────────────────────────────────

/// The element type a `getXxx`/`setXxx` operates on, recovered from the method's `native_name`
/// (e.g. "getInt16", "setBigUint64"). A runtime descriptor (no `type` field, so it is NOT comptime-only):
/// `size` is the element byte size, `signed` distinguishes Int/Uint decode, `is_float`/`is_bigint` pick
/// the IEEE-754 / BigInt paths.
const View = struct {
    size: usize,
    signed: bool,
    is_float: bool,
    is_bigint: bool,
};

/// §25.3.4 Table — map the method's element name (the part after "get"/"set") to its `View`.
fn viewFor(elem_name: []const u8) ?View {
    const eql = std.mem.eql;
    if (eql(u8, elem_name, "Int8")) return .{ .size = 1, .signed = true, .is_float = false, .is_bigint = false };
    if (eql(u8, elem_name, "Uint8")) return .{ .size = 1, .signed = false, .is_float = false, .is_bigint = false };
    if (eql(u8, elem_name, "Int16")) return .{ .size = 2, .signed = true, .is_float = false, .is_bigint = false };
    if (eql(u8, elem_name, "Uint16")) return .{ .size = 2, .signed = false, .is_float = false, .is_bigint = false };
    if (eql(u8, elem_name, "Int32")) return .{ .size = 4, .signed = true, .is_float = false, .is_bigint = false };
    if (eql(u8, elem_name, "Uint32")) return .{ .size = 4, .signed = false, .is_float = false, .is_bigint = false };
    if (eql(u8, elem_name, "Float32")) return .{ .size = 4, .signed = false, .is_float = true, .is_bigint = false };
    if (eql(u8, elem_name, "Float64")) return .{ .size = 8, .signed = false, .is_float = true, .is_bigint = false };
    if (eql(u8, elem_name, "BigInt64")) return .{ .size = 8, .signed = true, .is_float = false, .is_bigint = true };
    if (eql(u8, elem_name, "BigUint64")) return .{ .size = 8, .signed = false, .is_float = false, .is_bigint = true };
    return null;
}

/// Dispatch a `DataView.prototype.{get,set}<Type>` call. `native_name` is the spec method name
/// ("getInt8", "setBigUint64", …). Routes to `getValue` / `setValue` with the recovered `View`.
pub fn method(it: *Interpreter, native_name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (std.mem.startsWith(u8, native_name, "get")) {
        const v = viewFor(native_name[3..]) orelse return it.throwError("TypeError", "unknown DataView method");
        return getValue(it, v, this_val, args);
    }
    if (std.mem.startsWith(u8, native_name, "set")) {
        const v = viewFor(native_name[3..]) orelse return it.throwError("TypeError", "unknown DataView method");
        return setValue(it, v, this_val, args);
    }
    return it.throwError("TypeError", "unknown DataView method");
}

/// §25.3.4 GetViewValue ( view, requestIndex, isLittleEndian, type ). Coerce the index via ToIndex,
/// bounds-check against the view (RangeError if `offset + size > byteLength`), TypeError on detached.
fn getValue(it: *Interpreter, view: View, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .data_view) {
        return it.throwError("TypeError", "DataView.prototype method called on a non-DataView");
    }
    const dv = this_val.object.data_view.?;

    // §25.3.4 GetViewValue step 3: getIndex = ToIndex(requestIndex). Observable, so it runs FIRST.
    const idx_arg: Value = if (args.len > 0) args[0] else .undefined;
    const ic = try toIndex(it, idx_arg);
    if (ic.isAbrupt()) return ic;
    const get_index: usize = @intFromFloat(ic.normal.number);

    // §25.3.4 step 4: isLittleEndian = ToBoolean(littleEndian). For getXxx the flag is arg[1].
    const little: bool = if (args.len > 1) abstract_ops.toBoolean(args[1]) else false;
    const endian: std.builtin.Endian = if (little) .little else .big;

    // §25.3.4 step 5–6: detach check + bounds check (must follow the observable ToIndex).
    const ab = dv.buffer.array_buffer.?;
    if (ab.detached) return it.throwError("TypeError", "Cannot read from a DataView on a detached buffer");
    // §25.3.4 GetViewByteLength — bound against the LIVE byte length (a tracking view follows the
    // resized buffer; a fixed view that the buffer shrank below reads out of bounds).
    if (get_index + view.size > liveByteLength(dv, ab.bytes.len)) {
        return it.throwError("RangeError", "DataView access is out of bounds");
    }

    const start = dv.byte_offset + get_index;
    // A resizable ArrayBuffer may have shrunk below the stored `byte_length`, so re-validate against the
    // LIVE buffer before slicing (§25.3.4: GetViewByteLength reflects the current buffer) — RangeError.
    if (start + view.size > ab.bytes.len) {
        return it.throwError("RangeError", "DataView access is out of bounds");
    }
    const raw = ab.bytes[start .. start + view.size];
    return readRaw(it, view, raw, endian);
}

/// §25.3.4 SetViewValue ( view, requestIndex, isLittleEndian, type, value ). ToIndex the index, coerce
/// the value (ToBigInt for the bigint set, else ToNumber), detach + bounds check, then write the bytes.
fn setValue(it: *Interpreter, view: View, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .data_view) {
        return it.throwError("TypeError", "DataView.prototype method called on a non-DataView");
    }
    const dv = this_val.object.data_view.?;

    // §25.3.4 SetViewValue step 3: getIndex = ToIndex(requestIndex) — observable, runs FIRST.
    const idx_arg: Value = if (args.len > 0) args[0] else .undefined;
    const ic = try toIndex(it, idx_arg);
    if (ic.isAbrupt()) return ic;
    const get_index: usize = @intFromFloat(ic.normal.number);

    // §25.3.4 step 6–7: numberValue/bigIntValue = ToBigInt/ToNumber(value). Coercion is observable and
    // ordered BEFORE the detach/bounds checks (the spec runs it before GetViewByteLength).
    const value_arg: Value = if (args.len > 1) args[1] else .undefined;
    var num: f64 = 0;
    var big_holder: ?Value = null;
    if (view.is_bigint) {
        const bc = try builtin_bigint.toBigIntPub(it, value_arg);
        if (bc.isAbrupt()) return bc;
        big_holder = bc.normal;
    } else {
        const nc = try it.toNumberThrowing(value_arg);
        if (nc.isAbrupt()) return nc;
        num = nc.normal.number;
    }

    // §25.3.4 step 8: isLittleEndian = ToBoolean(littleEndian). For setXxx the flag is arg[2].
    const little: bool = if (args.len > 2) abstract_ops.toBoolean(args[2]) else false;
    const endian: std.builtin.Endian = if (little) .little else .big;

    // §25.3.4 step 9–10: detach check + bounds check.
    const ab = dv.buffer.array_buffer.?;
    if (ab.detached) return it.throwError("TypeError", "Cannot write to a DataView on a detached buffer");
    // §25.3.4 SetViewValue — bound against the LIVE byte length (see getValue).
    if (get_index + view.size > liveByteLength(dv, ab.bytes.len)) {
        return it.throwError("RangeError", "DataView access is out of bounds");
    }

    const start = dv.byte_offset + get_index;
    // Re-validate against the LIVE buffer (a resizable ArrayBuffer may have shrunk below the stored
    // `byte_length` during the index/value coercions above) before slicing — RangeError.
    if (start + view.size > ab.bytes.len) {
        return it.throwError("RangeError", "DataView access is out of bounds");
    }
    const dst = ab.bytes[start .. start + view.size];
    writeRaw(view, dst, endian, num, big_holder);
    return .{ .normal = .undefined };
}

// ── raw byte read/write (explicit endianness) ────────────────────────────────

/// Decode `raw` (exactly `view.size` bytes) in `endian` order into a JS Value. The nine numeric types
/// yield a Number; the two 64-bit-integer types yield a BigInt allocated in the interpreter arena.
fn readRaw(it: *Interpreter, view: View, raw: []const u8, endian: std.builtin.Endian) EvalError!Completion {
    switch (view.size) {
        1 => {
            const b = raw[0];
            const n: f64 = if (view.signed) @floatFromInt(@as(i8, @bitCast(b))) else @floatFromInt(b);
            return .{ .normal = .{ .number = n } };
        },
        2 => {
            const u = std.mem.readInt(u16, raw[0..2], endian);
            const n: f64 = if (view.signed) @floatFromInt(@as(i16, @bitCast(u))) else @floatFromInt(u);
            return .{ .normal = .{ .number = n } };
        },
        4 => {
            const u = std.mem.readInt(u32, raw[0..4], endian);
            if (view.is_float) {
                return .{ .normal = .{ .number = @as(f64, @as(f32, @bitCast(u))) } };
            }
            const n: f64 = if (view.signed) @floatFromInt(@as(i32, @bitCast(u))) else @floatFromInt(u);
            return .{ .normal = .{ .number = n } };
        },
        8 => {
            const u = std.mem.readInt(u64, raw[0..8], endian);
            if (view.is_float) {
                return .{ .normal = .{ .number = @as(f64, @bitCast(u)) } };
            }
            // §25.3.4 BigInt64/BigUint64 → a BigInt.
            const bi = if (view.signed)
                bigint.fromI64(it.arena, @as(i64, @bitCast(u))) catch return error.OutOfMemory
            else
                try u64ToBigInt(it.arena, u);
            return .{ .normal = .{ .bigint = bi } };
        },
        else => unreachable,
    }
}

/// Encode the coerced value into `dst` (exactly `view.size` bytes) in `endian` order. Numeric writes
/// wrap per the codec's modular conversion (ToInt8/ToUint16/…); float writes round to the storage
/// precision; bigint writes take the low 64 bits (§25.3.4 ToBigInt64/ToBigUint64 — same bits either way).
fn writeRaw(view: View, dst: []u8, endian: std.builtin.Endian, num: f64, big: ?Value) void {
    // The modular wrap produces the SAME bit pattern for Int/Uint of a given width (two's complement),
    // so the signed conversion's bits serve both — only `getXxx` decode distinguishes signedness.
    switch (view.size) {
        1 => dst[0] = @bitCast(toInt(i8, num)),
        2 => std.mem.writeInt(u16, dst[0..2], @bitCast(toInt(i16, num)), endian),
        4 => {
            if (view.is_float) {
                std.mem.writeInt(u32, dst[0..4], @bitCast(@as(f32, @floatCast(num))), endian);
            } else {
                std.mem.writeInt(u32, dst[0..4], @bitCast(toInt(i32, num)), endian);
            }
        },
        8 => {
            if (view.is_float) {
                std.mem.writeInt(u64, dst[0..8], @bitCast(num), endian);
            } else {
                std.mem.writeInt(u64, dst[0..8], bigIntToU64Bits(big.?.bigint), endian);
            }
        },
        else => unreachable,
    }
}

// ── numeric helpers (mirrors typed_array.zig, but parameterised for DataView) ──

/// §7.1.* ToInt8/ToUint8/ToInt16/… — modular conversion of an already-ToNumber'd value. NaN/±Inf → 0;
/// otherwise truncate toward zero then take the low bits (two's-complement wrap).
fn toInt(comptime Int: type, num: f64) Int {
    if (!std.math.isFinite(num)) return 0;
    const t = @trunc(num);
    const bits = @typeInfo(Int).int.bits;
    const Wide = std.meta.Int(.unsigned, 64);
    const modulus: f64 = std.math.pow(f64, 2, @floatFromInt(bits));
    var r = @mod(t, modulus);
    if (r < 0) r += modulus;
    const u: Wide = @intFromFloat(r);
    const Unsigned = std.meta.Int(.unsigned, bits);
    const low: Unsigned = @truncate(u);
    return @bitCast(low);
}

/// A BigInt holding the (non-negative) value of a raw `u64` — for the BigUint64 get path.
fn u64ToBigInt(arena: std.mem.Allocator, v: u64) std.mem.Allocator.Error!*const std.math.big.int.Const {
    if (v <= std.math.maxInt(i64)) return bigint.fromI64(arena, @intCast(v)) catch error.OutOfMemory;
    const signed = bigint.fromI64(arena, @as(i64, @bitCast(v))) catch return error.OutOfMemory;
    return bigint.asUintN(arena, 64, signed) catch error.OutOfMemory;
}

/// §25.3.4 ToBigInt64/ToBigUint64 — the low 64 bits of a BigInt (modulo 2^64) as a `u64` bit pattern.
fn bigIntToU64Bits(v: *const std.math.big.int.Const) u64 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const wrapped = bigint.asUintN(scratch.allocator(), 64, v) catch return 0;
    return wrapped.toInt(u64) catch 0;
}

// ── §7.1.22 ToIndex ──────────────────────────────────────────────────────────

/// §7.1.22 ToIndex(value): ToIntegerOrInfinity, then a [0, 2^53-1] integer range check (negative or
/// > 2^53-1 → RangeError). undefined → 0. Returns the integral value as a Number in `.normal`.
fn toIndex(it: *Interpreter, v: Value) EvalError!Completion {
    if (v == .undefined) return .{ .normal = .{ .number = 0 } };
    const c = try it.toIntegerOrInfinity(v);
    if (c.isAbrupt()) return c;
    const n = c.normal.number;
    if (n < 0 or n > 9007199254740991.0) {
        return it.throwError("RangeError", "Invalid DataView index");
    }
    return .{ .normal = .{ .number = n } };
}
