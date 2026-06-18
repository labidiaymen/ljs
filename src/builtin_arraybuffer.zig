//! §25.1 ArrayBuffer — Phase 2-A FULL surface (spec 083): `new ArrayBuffer(length[, options])`
//! (fixed or RESIZABLE via the `maxByteLength` option), the `byteLength` / `maxByteLength` /
//! `resizable` getters, `ArrayBuffer.prototype.slice` (species-aware), `ArrayBuffer.prototype.resize`,
//! the `ArrayBuffer.isView` static, `get ArrayBuffer[Symbol.species]` (returns `this`), and
//! `[Symbol.toStringTag] = "ArrayBuffer"`. Dispatched from the interpreter's `callNative` /
//! `constructNT`. The element codecs that read/write the backing bytes live in `typed_array.zig`
//! (shared with TypedArray + DataView). Detach semantics: a detached buffer reports byteLength 0 and
//! `slice`/`resize` throw a TypeError (§25.1.5.x RequireInternalSlot + IsDetachedBuffer checks).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const isConstructor = interp.isConstructor;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;

/// %ArrayBuffer.prototype% — the [[Prototype]] of every ArrayBuffer instance. Null in a realm-less eval.
fn arrayBufferProto(it: *Interpreter) ?*Object {
    return it.globalProto("ArrayBuffer");
}

/// The realm's %ArrayBuffer% constructor object (the default Symbol.species intrinsic). Null in a
/// realm-less unit-test eval.
fn arrayBufferCtor(it: *Interpreter) ?*Object {
    const g = it.globals orelse return null;
    const b = g.lookup("ArrayBuffer") orelse return null;
    return if (b.value == .object) b.value.object else null;
}

/// §7.1.22 ToIndex(value): ToIntegerOrInfinity then a [0, 2^53-1] range check (negative / non-integer
/// Infinity → RangeError). Returns the index, or propagates the abrupt completion in `err`.
const IndexResult = union(enum) { ok: usize, abrupt: Completion };
fn toIndex(it: *Interpreter, v: Value) EvalError!IndexResult {
    const lc = try it.toIntegerOrInfinity(v);
    if (lc.isAbrupt()) return .{ .abrupt = lc };
    const n = lc.normal.number;
    if (n < 0 or n > 9007199254740991.0) {
        return .{ .abrupt = try it.throwError("RangeError", "Invalid index") };
    }
    return .{ .ok = @intFromFloat(n) };
}

/// §25.1.1.1 GetArrayBufferMaxByteLengthOption ( options ): if `options` is an Object, read its
/// `maxByteLength` property; an `undefined` value (or a non-object options) → EMPTY (fixed buffer);
/// otherwise ToIndex(value). Returns null for EMPTY, the value for a resizable request, or abrupt.
const MaxLenResult = union(enum) { empty, len: usize, abrupt: Completion };
fn getMaxByteLengthOption(it: *Interpreter, options: Value) EvalError!MaxLenResult {
    if (options != .object) return .empty;
    const mc = try it.getProperty(options, "maxByteLength");
    if (mc.isAbrupt()) return .{ .abrupt = mc };
    if (mc.normal == .undefined) return .empty;
    const ic = try toIndex(it, mc.normal);
    return switch (ic) {
        .ok => |n| .{ .len = n },
        .abrupt => |a| .{ .abrupt = a },
    };
}

/// §25.1.3.1 `new ArrayBuffer(length[, options])` — [[Construct]]. `this_val` is the pre-created
/// instance (proto-linked to new_target.prototype) handed in by `constructNT`; flip it into an
/// `array_buffer` exotic over `ToIndex(length)` zeroed bytes. With a `maxByteLength` option the buffer
/// is RESIZABLE (over-allocate? no — allocate the requested length now, store the cap; `resize` grows
/// in place by reallocating the data block). A plain call (no `new`) is a TypeError (§25.1.3.1 step 1)
/// — handled by the caller in `callNative`.
pub fn construct(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const len_arg: Value = if (args.len > 0) args[0] else .undefined;
    const options: Value = if (args.len > 1) args[1] else .undefined;

    // §7.1.22 ToIndex(length) — negative / non-integer Infinity → RangeError; object runs ToPrimitive.
    const len_ic = try toIndex(it, len_arg);
    const byte_length: usize = switch (len_ic) {
        .ok => |n| n,
        .abrupt => |a| return a,
    };

    // §25.1.1.1 the `maxByteLength` option (read AFTER ToIndex(length), per spec ordering) — present →
    // a resizable buffer; the cap must be ≥ the requested length, else RangeError (§25.1.3.1 step 4).
    const max_opt = try getMaxByteLengthOption(it, options);
    const max_byte_length: ?usize = switch (max_opt) {
        .empty => null,
        .len => |m| blk: {
            if (byte_length > m) return it.throwError("RangeError", "ArrayBuffer: byteLength exceeds maxByteLength");
            break :blk m;
        },
        .abrupt => |a| return a,
    };

    // §25.1.3.1 AllocateArrayBuffer: build the exotic on the pre-created instance so subclassing
    // (`class B extends ArrayBuffer`) works — `this_val` already carries new_target.prototype.
    const obj: *Object = if (this_val == .object) this_val.object else try Object.create(it.arena, arrayBufferProto(it));
    obj.kind = .array_buffer;
    // §25.1.3.1: a request the host cannot satisfy is a RangeError, NOT a fatal engine OOM.
    const bytes = it.arena.alloc(u8, byte_length) catch return it.throwError("RangeError", "ArrayBuffer allocation failed");
    @memset(bytes, 0);
    obj.array_buffer = .{ .bytes = bytes, .detached = false, .max_byte_length = max_byte_length };
    return .{ .normal = .{ .object = obj } };
}

/// §25.1.6.x ArrayBuffer.prototype getters — `native_name` selects byteLength / maxByteLength /
/// resizable / detached. The receiver must be an ArrayBuffer (not a TypedArray/DataView), else
/// TypeError per RequireInternalSlot.
pub fn getter(it: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .array_buffer) {
        return it.throwError("TypeError", "ArrayBuffer.prototype getter called on a non-ArrayBuffer");
    }
    const ab = this_val.object.array_buffer.?;
    if (std.mem.eql(u8, name, "byteLength")) {
        // §25.1.6.1 step 4: a detached buffer reports byteLength 0.
        const n: usize = if (ab.detached) 0 else ab.bytes.len;
        return .{ .normal = .{ .number = @floatFromInt(n) } };
    }
    if (std.mem.eql(u8, name, "maxByteLength")) {
        // §25.1.6.4 get maxByteLength: detached → 0; resizable → [[ArrayBufferMaxByteLength]];
        // a fixed (non-resizable) buffer reports its (current) byteLength.
        if (ab.detached) return .{ .normal = .{ .number = 0 } };
        const n: usize = ab.max_byte_length orelse ab.bytes.len;
        return .{ .normal = .{ .number = @floatFromInt(n) } };
    }
    if (std.mem.eql(u8, name, "resizable")) {
        // §25.1.6.3 get resizable: IsResizableArrayBuffer ⇔ [[ArrayBufferMaxByteLength]] is present.
        return .{ .normal = .{ .boolean = ab.max_byte_length != null } };
    }
    if (std.mem.eql(u8, name, "detached")) {
        // §25.1.6.2 get detached: IsDetachedBuffer.
        return .{ .normal = .{ .boolean = ab.detached } };
    }
    return .{ .normal = .undefined };
}

/// §25.1.6.x ArrayBuffer.prototype methods — `native_name` selects `slice` / `resize`.
pub fn method(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "slice")) return slice(it, this_val, args);
    if (std.mem.eql(u8, name, "resize")) return resize(it, this_val, args);
    return it.throwError("TypeError", "Unknown ArrayBuffer.prototype method");
}

/// §25.1.6.x ArrayBuffer statics — `native_name` selects `isView`.
pub fn static(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "isView")) {
        // §25.1.4.1 ArrayBuffer.isView(arg): true iff arg is an object with a [[ViewedArrayBuffer]]
        // slot — i.e. a TypedArray (Integer-Indexed) or a DataView.
        const arg: Value = if (args.len > 0) args[0] else .undefined;
        const is_view = arg == .object and (arg.object.kind == .typed_array or arg.object.kind == .data_view);
        return .{ .normal = .{ .boolean = is_view } };
    }
    return it.throwError("TypeError", "Unknown ArrayBuffer static method");
}

/// §25.1.6.7 ArrayBuffer.prototype.slice ( start, end ) — RequireInternalSlot + IsDetachedBuffer →
/// TypeError; clamp the relative [start, end) indices into [0, len]; SpeciesConstructor a new
/// ArrayBuffer of the resulting length (default %ArrayBuffer%); copy the bytes. The species result is
/// re-validated (must be an ArrayBuffer, not detached, not the same buffer, large enough).
pub fn slice(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .array_buffer) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.slice called on a non-ArrayBuffer");
    }
    const self_obj = this_val.object;
    if (self_obj.array_buffer.?.detached) {
        return it.throwError("TypeError", "Cannot slice a detached ArrayBuffer");
    }
    const len: f64 = @floatFromInt(self_obj.array_buffer.?.bytes.len);

    // §25.1.6.7 steps 5-9: ToIntegerOrInfinity(start), then RelativeIndex into [0, len].
    const start_arg: Value = if (args.len > 0) args[0] else .undefined;
    const sc = try it.toIntegerOrInfinity(start_arg);
    if (sc.isAbrupt()) return sc;
    const first = relativeIndex(sc.normal.number, len);

    // steps 10-12: end (undefined → len), RelativeIndex into [0, len].
    const end_arg: Value = if (args.len > 1) args[1] else .undefined;
    const final: f64 = if (end_arg == .undefined) len else blk: {
        const ec = try it.toIntegerOrInfinity(end_arg);
        if (ec.isAbrupt()) return ec;
        break :blk relativeIndex(ec.normal.number, len);
    };

    // step 13: newLen = max(final - first, 0).
    const new_len: usize = if (final > first) @intFromFloat(final - first) else 0;

    // steps 14-16: SpeciesConstructor(O, %ArrayBuffer%), then Construct(ctor, « newLen »).
    const ctor = try speciesConstructor(it, self_obj);
    const new_v: Value = switch (ctor) {
        .abrupt => |a| return a,
        .ctor => |c| blk: {
            const cc = try it.construct(c, &.{.{ .number = @floatFromInt(new_len) }});
            if (cc.isAbrupt()) return cc;
            break :blk cc.normal;
        },
    };

    // steps 17-20: the species result must be an ArrayBuffer, not detached, not the same buffer, and
    // its byteLength ≥ newLen.
    if (new_v != .object or new_v.object.kind != .array_buffer) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.slice: species did not return an ArrayBuffer");
    }
    const new_obj = new_v.object;
    if (new_obj.array_buffer.?.detached) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.slice: species returned a detached ArrayBuffer");
    }
    if (new_obj == self_obj) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.slice: species returned the same ArrayBuffer");
    }
    if (new_obj.array_buffer.?.bytes.len < new_len) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.slice: species returned too-small an ArrayBuffer");
    }

    // step 21: the source must not have been detached by the species constructor (re-check).
    if (self_obj.array_buffer.?.detached) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.slice: source detached during species construction");
    }

    // steps 22-23: CopyDataBlockBytes(toBlock, 0, fromBlock, first, newLen).
    if (new_len > 0) {
        const src = self_obj.array_buffer.?.bytes;
        const dst = new_obj.array_buffer.?.bytes;
        const f: usize = @intFromFloat(first);
        @memcpy(dst[0..new_len], src[f .. f + new_len]);
    }
    return .{ .normal = .{ .object = new_obj } };
}

/// §25.1.6.x ArrayBuffer.prototype.resize ( newLength ) — RequireInternalSlot + IsResizableArrayBuffer
/// (a fixed buffer → TypeError); ToIndex(newLength); newLength > [[ArrayBufferMaxByteLength]] →
/// RangeError; detached → TypeError. Reallocate the data block to `newLength`, zero-filling any growth.
pub fn resize(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.kind != .array_buffer) {
        return it.throwError("TypeError", "ArrayBuffer.prototype.resize called on a non-ArrayBuffer");
    }
    const self_obj = this_val.object;
    const max = self_obj.array_buffer.?.max_byte_length orelse {
        return it.throwError("TypeError", "ArrayBuffer.prototype.resize: buffer is not resizable");
    };

    const len_arg: Value = if (args.len > 0) args[0] else .undefined;
    const ic = try toIndex(it, len_arg);
    const new_len: usize = switch (ic) {
        .ok => |n| n,
        .abrupt => |a| return a,
    };

    // §25.1.6.x step (after ToIndex): newByteLength > [[ArrayBufferMaxByteLength]] → RangeError. The
    // detached check follows (a resizable buffer can still be detached via transfer in future phases).
    if (new_len > max) {
        return it.throwError("RangeError", "ArrayBuffer.prototype.resize: newLength exceeds maxByteLength");
    }
    if (self_obj.array_buffer.?.detached) {
        return it.throwError("TypeError", "Cannot resize a detached ArrayBuffer");
    }

    // Reallocate the data block (arena-owned): copy the retained prefix, zero any growth. A failed
    // allocation maps to a RangeError, never a fatal OOM.
    const old = self_obj.array_buffer.?.bytes;
    const fresh = it.arena.alloc(u8, new_len) catch return it.throwError("RangeError", "ArrayBuffer.prototype.resize: allocation failed");
    const keep = @min(old.len, new_len);
    @memcpy(fresh[0..keep], old[0..keep]);
    if (new_len > keep) @memset(fresh[keep..], 0);
    self_obj.array_buffer.?.bytes = fresh;
    return .{ .normal = .undefined };
}

/// §7.3.22-ish RelativeIndex(n, len): a negative `n` is relative to the end (max(len+n, 0)); a
/// non-negative `n` is clamped to `len`. (+Infinity → len; -Infinity → 0.) Returns the integral index
/// as f64 (callers cast to usize after the [0, len] clamp).
fn relativeIndex(n: f64, len: f64) f64 {
    if (n < 0) return @max(len + n, 0);
    return @min(n, len);
}

/// §7.3.23 SpeciesConstructor(O, %ArrayBuffer%) restricted to slice's needs: C = Get(O, "constructor");
/// undefined → default. If Type(C) is Object, S = Get(C, @@species); null/undefined S → default. S must
/// be a constructor, else TypeError. Returns the resolved constructor Object (default %ArrayBuffer%).
const CtorResult = union(enum) { ctor: *Object, abrupt: Completion };
fn speciesConstructor(it: *Interpreter, o: *Object) EvalError!CtorResult {
    const default_ctor = arrayBufferCtor(it);

    const cc = try it.getProperty(.{ .object = o }, "constructor");
    if (cc.isAbrupt()) return .{ .abrupt = cc };
    var c = cc.normal;
    if (c == .undefined) {
        if (default_ctor) |d| return .{ .ctor = d };
        return .{ .abrupt = try it.throwError("TypeError", "ArrayBuffer slice: no default constructor") };
    }
    if (c != .object) {
        return .{ .abrupt = try it.throwError("TypeError", "ArrayBuffer slice: constructor is not an object") };
    }
    if (it.wellKnownSpecies()) |sp| {
        const sc = try it.getSymbolProperty(c, sp);
        if (sc.isAbrupt()) return .{ .abrupt = sc };
        c = sc.normal;
    } else {
        c = .undefined; // realm-less eval: no species symbol → use the default constructor.
    }
    if (c == .undefined or c == .null) {
        if (default_ctor) |d| return .{ .ctor = d };
        return .{ .abrupt = try it.throwError("TypeError", "ArrayBuffer slice: no default constructor") };
    }
    if (c != .object or !isConstructor(c.object)) {
        return .{ .abrupt = try it.throwError("TypeError", "ArrayBuffer slice: species is not a constructor") };
    }
    return .{ .ctor = c.object };
}
