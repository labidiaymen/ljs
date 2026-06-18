//! §25.1 ArrayBuffer — Phase 1 MINIMAL surface: `new ArrayBuffer(length)` (allocate a zeroed,
//! allocator-owned byte block), the `byteLength` getter, and `[Symbol.toStringTag] = "ArrayBuffer"`.
//! The full surface (`slice`, `isView`, `Symbol.species`, resizable buffers, detach semantics) is
//! Phase 2-A. Dispatched from the interpreter's `callNative` / `constructNT`. The element codecs that
//! read/write the backing bytes live in `typed_array.zig` (shared with TypedArray + DataView).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;

/// %ArrayBuffer.prototype% — the [[Prototype]] of every ArrayBuffer instance. Null in a realm-less eval.
fn arrayBufferProto(it: *Interpreter) ?*Object {
    return it.globalProto("ArrayBuffer");
}

/// §25.1.2.1 / §25.1.3.1 `new ArrayBuffer(length[, options])` — [[Construct]]. `this_val` is the
/// pre-created instance (proto-linked to new_target.prototype) handed in by `constructNT`; flip it into
/// an `array_buffer` exotic over `ToIndex(length)` zeroed bytes. (Resizable `maxByteLength` options are
/// Phase 2-A; Phase 1 allocates a fixed-length buffer.) A plain call (no `new`) is a TypeError (§25.1.3.1
/// step 1) — handled by the caller in `callNative`.
pub fn construct(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    // §7.1.22 ToIndex(length): ToIntegerOrInfinity then a [0, 2^53-1] range check (negative / non-integer
    // Infinity → RangeError). An object length runs ToPrimitive (observable). undefined → 0.
    const len_arg: Value = if (args.len > 0) args[0] else .undefined;
    const lc = try it.toIntegerOrInfinity(len_arg);
    if (lc.isAbrupt()) return lc;
    const len_n = lc.normal.number;
    if (len_n < 0 or len_n > 9007199254740991.0) {
        return it.throwError("RangeError", "Invalid ArrayBuffer length");
    }
    const byte_length: usize = @intFromFloat(len_n);

    // §25.1.2.1 AllocateArrayBuffer: build the exotic on the pre-created instance so subclassing
    // (`class B extends ArrayBuffer`) works — `this_val` already carries new_target.prototype.
    const obj: *Object = if (this_val == .object) this_val.object else try Object.create(it.arena, arrayBufferProto(it));
    obj.kind = .array_buffer;
    // §25.1.2.1 step 2: allocate a zeroed data block. A request the host cannot satisfy (e.g.
    // `new ArrayBuffer(2**53-1)` — within ToIndex range but unallocatable) is a RangeError, NOT a
    // fatal engine OOM — so map the allocator failure to the JS exception the test expects.
    const bytes = it.arena.alloc(u8, byte_length) catch return it.throwError("RangeError", "ArrayBuffer allocation failed");
    @memset(bytes, 0);
    obj.array_buffer = .{ .bytes = bytes, .detached = false, .max_byte_length = null };
    return .{ .normal = .{ .object = obj } };
}

/// §25.1.6.1 get ArrayBuffer.prototype.byteLength — the [[ArrayBufferByteLength]] (0 if detached).
/// `native_name` selects the getter (Phase 1 wires only `byteLength`; Phase 2-A adds `maxByteLength` /
/// `resizable` / `detached`). The receiver must be an ArrayBuffer (not a TypedArray/DataView), else
/// TypeError per §25.1.6.1 step 2-3 (RequireInternalSlot).
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
    // Unknown getter (Phase 2-A territory) — defensively return undefined rather than crash.
    return .{ .normal = .undefined };
}
