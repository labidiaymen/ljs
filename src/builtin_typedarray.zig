//! §23.2 TypedArray objects — the `%TypedArray%` abstract super-constructor, the 11 concrete
//! constructors (`Int8Array`…`BigUint64Array`), the prototype getters, the ~35 prototype methods, and
//! the `from`/`of`/`Symbol.species` statics. Dispatched from the interpreter's `callNative`
//! (`typed_array_abstract_ctor`/`typed_array_proto_getter`/`typed_array_method`/`typed_array_static`)
//! and `constructNT` (`typed_array_ctor`). Element get/set is the foundation's codec (`typed_array.zig`)
//! over the shared `ArrayBuffer` backing store; the integer-indexed `ta[i]` exotic get/set already lives
//! in `interp_property.zig`. Construction overloads, species-create, and the detached/OOB guards here
//! follow §23.2.5 / §23.2.3.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ElemType = @import("typed_array.zig").ElemType;
const tarray = @import("typed_array.zig");
const ops = @import("abstract_ops.zig");
const interp_property = @import("interp_property.zig");
const builtin_bigint = @import("builtin_bigint.zig");

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Element-type resolution + small slot accessors
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// The 11 concrete element types in spec order (used to register the constructors and to map a
/// constructor-name `native_name` back to its `ElemType`).
pub const all_elems = [_]ElemType{ .i8, .u8, .u8_clamped, .i16, .u16, .i32, .u32, .f32, .f64, .i64, .u64 };

/// Map a constructor-name string (`"Int8Array"`, …) to its element type. `null` for `"TypedArray"`
/// (the abstract super) or any non-concrete name.
fn elemForName(name: []const u8) ?ElemType {
    for (all_elems) |e| {
        if (std.mem.eql(u8, e.constructorName(), name)) return e;
    }
    return null;
}

/// A live view onto a TypedArray receiver: its `TypedArrayData` plus the (possibly detached) buffer.
const TA = struct {
    obj: *Object,
    elem: ElemType,
    /// The backing bytes slice starting at the view's byteOffset, or null when detached.
    bytes: ?[]u8,
    length: usize,

    fn of(o: *Object) TA {
        const ta = o.typed_array.?;
        const buf = ta.buffer.array_buffer;
        const detached = buf == null or buf.?.detached;
        // Clamp the byteOffset: a resizable ArrayBuffer may have shrunk BELOW the view's byteOffset, so
        // even `bytes[byteOffset..]` would be out of range — yield an empty live slice (length 0) instead.
        const live = if (detached) null else buf.?.bytes[@min(ta.byte_offset, buf.?.bytes.len)..];
        return .{
            .obj = o,
            .elem = ta.elem,
            .bytes = live,
            // §10.4.5.11 TypedArrayLength: for a length-TRACKING view (resizable buffer, no explicit
            // length) the length is recomputed from the LIVE buffer; for a fixed view the stored
            // `array_length` is clamped to what the live slice holds (crash-safe; a resizable buffer may
            // have shrunk below the stored length during argument coercion's user `valueOf`). For a
            // non-resizable buffer this is exactly `array_length` (no behavior change).
            .length = if (detached) 0 else tarray.liveLength(ta.tracks_length, ta.array_length, ta.byte_offset, buf.?.bytes.len, ta.elem.bytesPerElement()),
        };
    }

    fn get(self: TA, it: *Interpreter, i: usize) std.mem.Allocator.Error!Value {
        return tarray.getElement(self.elem, self.bytes.?, i, it.arena);
    }
};

/// `this` must be a TypedArray exotic; else a §23.2.3 ValidateTypedArray TypeError.
fn requireTA(it: *Interpreter, this_val: Value) EvalError!union(enum) { ta: *Object, abrupt: Completion } {
    if (this_val != .object or this_val.object.kind != .typed_array) {
        return .{ .abrupt = try it.throwError("TypeError", "method called on a non-TypedArray") };
    }
    return .{ .ta = this_val.object };
}

/// True when the receiver's buffer is detached (an out-of-band check used by §23.2.3 operations that
/// must throw on detachment).
fn isDetached(o: *Object) bool {
    const ta = o.typed_array.?;
    const buf = ta.buffer.array_buffer;
    return buf == null or buf.?.detached;
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Construction (§23.2.5)
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// §23.2.5.1 the abstract `%TypedArray%(...)` — direct construction always throws (§23.2.1.1 step 1).
pub fn constructAbstract(it: *Interpreter) EvalError!Completion {
    return it.throwError("TypeError", "Abstract class TypedArray not directly constructable");
}

/// §23.2.5.1 `new <Type>Array(...)` — the four overloads, dispatched on the first argument's shape.
/// `new_obj` is the pre-created instance (proto-linked to new_target.prototype) handed in by constructNT.
/// `elem` is the concrete element type selected by the constructor's `native_name`.
pub fn construct(it: *Interpreter, new_obj: *Object, elem: ElemType, args: []const Value) EvalError!Completion {
    const arg0: Value = if (args.len > 0) args[0] else .undefined;
    if (arg0 == .object) {
        const o = arg0.object;
        if (o.kind == .typed_array) return constructFromTypedArray(it, new_obj, elem, o);
        if (o.kind == .array_buffer) return constructFromBuffer(it, new_obj, elem, o, args);
        // §23.2.5.1 step 5: any other object — iterable (Symbol.iterator) or array-like.
        return constructFromObject(it, new_obj, elem, o);
    }
    // §23.2.5.1 step 6: a non-object first arg (or none) is a length.
    return constructFromLength(it, new_obj, elem, arg0);
}

/// §23.2.5.1.1 AllocateTypedArray with a fresh zeroed buffer of `length` elements.
fn constructFromLength(it: *Interpreter, new_obj: *Object, elem: ElemType, len_arg: Value) EvalError!Completion {
    // §7.1.22 ToIndex(length): undefined → 0; ToIntegerOrInfinity then a [0, 2^53-1] check.
    var length: usize = 0;
    if (len_arg != .undefined) {
        const lc = try it.toIntegerOrInfinity(len_arg);
        if (lc.isAbrupt()) return lc;
        const n = lc.normal.number;
        if (n < 0 or n > 9007199254740991.0) return it.throwError("RangeError", "Invalid typed array length");
        length = @intFromFloat(n);
    }
    return allocWithBuffer(it, new_obj, elem, length);
}

/// §23.2.5.1.3 InitializeTypedArrayFromTypedArray — copy `src`'s elements into a new buffer. The
/// content types must match (both number, or both bigint) — else a TypeError (§23.2.5.1.3 step 18).
fn constructFromTypedArray(it: *Interpreter, new_obj: *Object, elem: ElemType, src_obj: *Object) EvalError!Completion {
    if (isDetached(src_obj)) return it.throwError("TypeError", "Cannot construct from a detached buffer");
    if (elem.contentType() != src_obj.typed_array.?.elem.contentType()) {
        return it.throwError("TypeError", "Cannot mix BigInt and Number typed arrays");
    }
    const src = TA.of(src_obj);
    const c = try allocWithBuffer(it, new_obj, elem, src.length);
    if (c.isAbrupt()) return c;
    const dst = TA.of(new_obj);
    var i: usize = 0;
    while (i < src.length) : (i += 1) {
        const v = try src.get(it, i);
        try writeElem(it, dst, i, v);
    }
    return .{ .normal = .{ .object = new_obj } };
}

/// §23.2.5.1.5 InitializeTypedArrayFromArrayBuffer — VIEW the existing buffer (shared storage). Validates
/// `byteOffset` alignment and, when `length` is undefined, that the remaining bytes divide evenly.
fn constructFromBuffer(it: *Interpreter, new_obj: *Object, elem: ElemType, buf: *Object, args: []const Value) EvalError!Completion {
    const bpe = elem.bytesPerElement();
    // §23.2.5.1.5 step 2: offset = ToIndex(byteOffset).
    var offset: usize = 0;
    if (args.len > 1 and args[1] != .undefined) {
        const oc = try it.toIntegerOrInfinity(args[1]);
        if (oc.isAbrupt()) return oc;
        const n = oc.normal.number;
        if (n < 0 or n > 9007199254740991.0) return it.throwError("RangeError", "Invalid byteOffset");
        offset = @intFromFloat(n);
    }
    // §23.2.5.1.5 step 4: offset must be a multiple of the element size.
    if (offset % bpe != 0) return it.throwError("RangeError", "byteOffset is not aligned");

    // §23.2.5.1.5 step 6-7: an explicit length (ToIndex) vs "to the end of the buffer".
    var explicit_len: ?usize = null;
    if (args.len > 2 and args[2] != .undefined) {
        const lc = try it.toIntegerOrInfinity(args[2]);
        if (lc.isAbrupt()) return lc;
        const n = lc.normal.number;
        if (n < 0 or n > 9007199254740991.0) return it.throwError("RangeError", "Invalid length");
        explicit_len = @intFromFloat(n);
    }
    // §23.2.5.1.5 step 8: re-check detachment AFTER the (observable) coercions above.
    const ab = buf.array_buffer.?;
    if (ab.detached) return it.throwError("TypeError", "Cannot view a detached buffer");
    const buffer_len = ab.bytes.len;

    var array_len: usize = 0;
    if (explicit_len) |l| {
        // §23.2.5.1.5 step 10: offset + length*bpe must fit in the buffer.
        const need = offset + l * bpe;
        if (need > buffer_len) return it.throwError("RangeError", "Invalid typed array length");
        array_len = l;
    } else {
        // §23.2.5.1.5 step 9: the buffer length minus offset must divide evenly by the element size.
        if (buffer_len % bpe != 0) return it.throwError("RangeError", "Buffer length is not aligned");
        if (offset > buffer_len) return it.throwError("RangeError", "byteOffset exceeds buffer length");
        array_len = (buffer_len - offset) / bpe;
    }

    // §10.4.5 a view over a RESIZABLE buffer with NO explicit length tracks the live buffer length.
    const tracks = (explicit_len == null) and (ab.max_byte_length != null);
    new_obj.kind = .typed_array;
    new_obj.typed_array = .{ .buffer = buf, .byte_offset = offset, .array_length = array_len, .elem = elem, .tracks_length = tracks };
    return .{ .normal = .{ .object = new_obj } };
}

/// §23.2.5.1.4 InitializeTypedArrayFromList / §23.2.5.1.6 InitializeTypedArrayFromArrayLike — for an
/// arbitrary object first argument: if it is iterable, drain its iterator into a list; else treat it as
/// array-like (read `length` + each index). Then allocate a fresh buffer and write each element.
fn constructFromObject(it: *Interpreter, new_obj: *Object, elem: ElemType, o: *Object) EvalError!Completion {
    // §23.2.5.1 step 5.b: usingIterator = GetMethod(O, @@iterator).
    const iter_sym = wellKnownSymbol(it, "iterator");
    var has_iter = false;
    if (iter_sym) |s| {
        const mc = try it.getSymbolProperty(.{ .object = o }, s);
        if (mc.isAbrupt()) return mc;
        has_iter = (mc.normal == .object and mc.normal.object.kind == .function);
    }

    if (!has_iter) {
        // §23.2.5.1.6 InitializeTypedArrayFromArrayLike — length = LengthOfArrayLike(O); allocate the
        // buffer FIRST (a huge length is a graceful RangeError, never an engine OOM), then Get + write
        // each index. No intermediate list, so an array-like with an enormous `length` cannot exhaust
        // memory building a Value list before the (failing) allocation.
        const len = switch (try it.lengthOfArrayLike(o)) {
            .len => |l| l,
            .abrupt => |c| return c,
        };
        const c = try allocWithBuffer(it, new_obj, elem, len);
        if (c.isAbrupt()) return c;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
            const gc = try it.getProperty(.{ .object = o }, key);
            if (gc.isAbrupt()) return gc;
            if (try writeElemChecked(it, new_obj, @floatFromInt(i), gc.normal)) |ac| return ac;
        }
        return .{ .normal = .{ .object = new_obj } };
    }

    // §23.2.5.1.4 InitializeTypedArrayFromList — an iterable's length is unknown up front, so drain it
    // into a list, then allocate a buffer of the resulting length and write each element.
    var list: std.ArrayListUnmanaged(Value) = .empty;
    const ic = try it.iterateToList(.{ .object = o }, &list);
    if (ic.isAbrupt()) return ic;
    const c = try allocWithBuffer(it, new_obj, elem, list.items.len);
    if (c.isAbrupt()) return c;
    const dst = TA.of(new_obj);
    for (list.items, 0..) |v, i| {
        try writeElem(it, dst, i, v);
    }
    return .{ .normal = .{ .object = new_obj } };
}

/// §23.2.5.1.1 AllocateTypedArrayBuffer — create a fresh zeroed ArrayBuffer of `length * bpe` bytes and
/// install it (+ the view slots) on `new_obj`. A too-large request maps to a JS RangeError, not a crash.
fn allocWithBuffer(it: *Interpreter, new_obj: *Object, elem: ElemType, length: usize) EvalError!Completion {
    const bpe = elem.bytesPerElement();
    const byte_len = std.math.mul(usize, length, bpe) catch
        return it.throwError("RangeError", "Invalid typed array length");
    const buf = Object.createArrayBuffer(it.arena, arrayBufferProto(it), byte_len, null) catch
        return it.throwError("RangeError", "Typed array allocation failed");
    new_obj.kind = .typed_array;
    new_obj.typed_array = .{ .buffer = buf, .byte_offset = 0, .array_length = length, .elem = elem };
    return .{ .normal = .{ .object = new_obj } };
}

/// Coerce `v` per the destination's content type (ToNumber / ToBigInt — observable) and write it into
/// element `i` of `dst` (assumed in bounds + non-detached). Returns the abrupt completion if coercion
/// throws (the value may not be a valid Number/BigInt), else writes the byte form.
fn writeElem(it: *Interpreter, dst: TA, i: usize, v: Value) EvalError!void {
    _ = try writeElemChecked(it, dst.obj, @floatFromInt(i), v);
}

/// §10.4.5.16 IntegerIndexedElementSet via the foundation: coerce + (in-bounds) byte write. Returns the
/// abrupt completion on a coercion throw, else null. `n` is the canonical numeric index.
fn writeElemChecked(it: *Interpreter, o: *Object, n: f64, v: Value) EvalError!?Completion {
    return interp_property.typedArraySet(it, o, n, v);
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Getters (§23.2.3) — `buffer` / `byteLength` / `byteOffset` / `length` / [Symbol.toStringTag]
// ─────────────────────────────────────────────────────────────────────────────────────────────────

pub fn getter(it: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    // §23.2.3.38 get [Symbol.toStringTag]: returns the constructor name for a TypedArray receiver, or
    // `undefined` (NOT a throw) for any other receiver.
    if (std.mem.eql(u8, name, "toStringTag")) {
        if (this_val == .object and this_val.object.kind == .typed_array) {
            return .{ .normal = .{ .string = this_val.object.typed_array.?.elem.constructorName() } };
        }
        return .{ .normal = .undefined };
    }
    if (this_val != .object or this_val.object.kind != .typed_array) {
        return it.throwError("TypeError", "TypedArray.prototype getter called on a non-TypedArray");
    }
    const ta = this_val.object.typed_array.?;
    const detached = isDetached(this_val.object);
    if (std.mem.eql(u8, name, "buffer")) {
        // §23.2.3.2 get buffer — the [[ViewedArrayBuffer]] (even when detached).
        return .{ .normal = .{ .object = ta.buffer } };
    }
    // §10.4.5.11 the LIVE length (tracking views follow the resized buffer; fixed views stay clamped).
    const live_len: usize = if (detached) 0 else tarray.liveLength(ta.tracks_length, ta.array_length, ta.byte_offset, ta.buffer.array_buffer.?.bytes.len, ta.elem.bytesPerElement());
    if (std.mem.eql(u8, name, "byteLength")) {
        // §23.2.3.3 — 0 when detached, else liveLength * bpe.
        const n: usize = live_len * ta.elem.bytesPerElement();
        return .{ .normal = .{ .number = @floatFromInt(n) } };
    }
    if (std.mem.eql(u8, name, "byteOffset")) {
        // §23.2.3.4 — 0 when detached, else [[ByteOffset]].
        const n: usize = if (detached) 0 else ta.byte_offset;
        return .{ .normal = .{ .number = @floatFromInt(n) } };
    }
    if (std.mem.eql(u8, name, "length")) {
        // §23.2.3.21 — 0 when detached, else the live length.
        return .{ .normal = .{ .number = @floatFromInt(live_len) } };
    }
    return .{ .normal = .undefined };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Statics (§23.2.2) — `from` / `of` / get [Symbol.species]
// ─────────────────────────────────────────────────────────────────────────────────────────────────

pub fn static(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "species")) return .{ .normal = this_val }; // §23.2.2.4 get [Symbol.species]
    if (std.mem.eql(u8, name, "of")) return staticOf(it, this_val, args);
    if (std.mem.eql(u8, name, "from")) return staticFrom(it, this_val, args);
    return it.throwError("TypeError", "unknown TypedArray static");
}

/// §23.2.2.2 %TypedArray%.of ( ...items ) — `this` must be a constructor; create a length-`items.len`
/// typed array via it and write each item.
fn staticOf(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or !interp.isCallable(this_val.object)) {
        return it.throwError("TypeError", "TypedArray.of requires a constructor receiver");
    }
    const created = switch (try typedArrayCreateFromCtor(it, this_val.object, &.{.{ .number = @floatFromInt(args.len) }})) {
        .obj => |o| o,
        .abrupt => |c| return c,
    };
    for (args, 0..) |v, i| {
        if (try writeElemChecked(it, created, @floatFromInt(i), v)) |c| return c;
    }
    return .{ .normal = .{ .object = created } };
}

/// §23.2.2.1 %TypedArray%.from ( source [ , mapfn [ , thisArg ] ] ).
fn staticFrom(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or !interp.isCallable(this_val.object)) {
        return it.throwError("TypeError", "TypedArray.from requires a constructor receiver");
    }
    const ctor = this_val.object;
    const source: Value = if (args.len > 0) args[0] else .undefined;
    const mapfn: Value = if (args.len > 1) args[1] else .undefined;
    const this_arg: Value = if (args.len > 2) args[2] else .undefined;
    var mapping = false;
    if (mapfn != .undefined) {
        if (mapfn != .object or !interp.isCallable(mapfn.object)) {
            return it.throwError("TypeError", "TypedArray.from mapfn is not callable");
        }
        mapping = true;
    }

    // §23.2.2.1 step 5: if source has @@iterator, collect via the iterator; else array-like.
    var list: std.ArrayListUnmanaged(Value) = .empty;
    const iter_sym = wellKnownSymbol(it, "iterator");
    var has_iter = false;
    if (source != .undefined and source != .null and iter_sym != null) {
        const mc = try it.getSymbolProperty(source, iter_sym.?);
        if (mc.isAbrupt()) return mc;
        has_iter = (mc.normal == .object and mc.normal.object.kind == .function);
    }
    if (has_iter) {
        const c = try it.iterateToList(source, &list);
        if (c.isAbrupt()) return c;
    } else {
        const oc = switch (try it.toObjectForArrayLike(source)) {
            .obj => |o| o,
            .abrupt => |c| return c,
        };
        const len = switch (try it.lengthOfArrayLike(oc)) {
            .len => |l| l,
            .abrupt => |c| return c,
        };
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
            const gc = try it.getProperty(.{ .object = oc }, key);
            if (gc.isAbrupt()) return gc;
            try list.append(it.arena, gc.normal);
        }
    }

    const created = switch (try typedArrayCreateFromCtor(it, ctor, &.{.{ .number = @floatFromInt(list.items.len) }})) {
        .obj => |o| o,
        .abrupt => |c| return c,
    };
    for (list.items, 0..) |v, i| {
        var mapped = v;
        if (mapping) {
            const mc = try it.callFunction(mapfn.object, &.{ v, .{ .number = @floatFromInt(i) } }, this_arg);
            if (mc.isAbrupt()) return mc;
            mapped = mc.normal;
        }
        if (try writeElemChecked(it, created, @floatFromInt(i), mapped)) |c| return c;
    }
    return .{ .normal = .{ .object = created } };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Species-create (§23.2.4.1 / §23.2.4.2)
// ─────────────────────────────────────────────────────────────────────────────────────────────────

const CreateResult = union(enum) { obj: *Object, abrupt: Completion };

/// §23.2.4.4 TypedArrayCreateFromConstructor ( constructor, argumentList ) — `new constructor(...args)`,
/// validating the result is a TypedArray (and, when one numeric length arg was passed, that its length
/// is at least that).
fn typedArrayCreateFromCtor(it: *Interpreter, ctor: *Object, args: []const Value) EvalError!CreateResult {
    const rc = try it.construct(ctor, args);
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    if (rc.normal != .object or rc.normal.object.kind != .typed_array) {
        return .{ .abrupt = try it.throwError("TypeError", "Species constructor did not return a TypedArray") };
    }
    const created = rc.normal.object;
    if (isDetached(created)) return .{ .abrupt = try it.throwError("TypeError", "Species constructor returned a detached buffer") };
    if (args.len == 1 and args[0] == .number) {
        const want: usize = @intFromFloat(args[0].number);
        if (created.typed_array.?.array_length < want) {
            return .{ .abrupt = try it.throwError("TypeError", "Derived typed array is too short") };
        }
    }
    return .{ .obj = created };
}

/// §23.2.4.1 TypedArraySpeciesCreate ( exemplar, argumentList ) — resolve the species constructor (via
/// `exemplar.constructor[@@species]`, defaulting to the same concrete %TypedArray% constructor) and
/// create a new typed array. The default-constructor fast path skips the species dance.
fn speciesCreate(it: *Interpreter, exemplar: *Object, args: []const Value) EvalError!CreateResult {
    const elem = exemplar.typed_array.?.elem;
    // §23.2.4.1 step 1: the default constructor for the exemplar's element type.
    const default_ctor = defaultConstructor(it, elem) orelse {
        // No realm constructor (realm-less eval): allocate directly.
        return directCreate(it, elem, args);
    };
    // §7.3.22 SpeciesConstructor(exemplar, defaultCtor).
    const ctor = switch (try speciesConstructor(it, exemplar, default_ctor)) {
        .obj => |c| c,
        .default => return typedArrayCreateFromCtor(it, default_ctor, args),
        .abrupt => |c| return .{ .abrupt = c },
    };
    return typedArrayCreateFromCtor(it, ctor, args);
}

const SpeciesResult = union(enum) { obj: *Object, default, abrupt: Completion };

/// §7.3.22 SpeciesConstructor ( O, defaultConstructor ). Reads `O.constructor`; if undefined → default;
/// then `C[@@species]`; if undefined/null → default; else it must be a constructor.
fn speciesConstructor(it: *Interpreter, o: *Object, default_ctor: *Object) EvalError!SpeciesResult {
    const cc = try it.getProperty(.{ .object = o }, "constructor");
    if (cc.isAbrupt()) return .{ .abrupt = cc };
    if (cc.normal == .undefined) return .default;
    if (cc.normal != .object) return .{ .abrupt = try it.throwError("TypeError", "constructor is not an object") };
    const species_sym = wellKnownSymbol(it, "species") orelse return .default;
    const sc = try it.getSymbolProperty(cc.normal, species_sym);
    if (sc.isAbrupt()) return .{ .abrupt = sc };
    if (sc.normal == .undefined or sc.normal == .null) return .default;
    if (sc.normal != .object or !interp.isCallable(sc.normal.object)) {
        return .{ .abrupt = try it.throwError("TypeError", "Symbol.species is not a constructor") };
    }
    if (sc.normal.object == default_ctor) return .default;
    return .{ .obj = sc.normal.object };
}

/// Directly allocate a fresh typed array of the given element type (the realm-less / default fallback).
/// `args` is a single length (or a copy source per the overloads); only the length form is used here.
fn directCreate(it: *Interpreter, elem: ElemType, args: []const Value) EvalError!CreateResult {
    const length: usize = if (args.len == 1 and args[0] == .number) @intFromFloat(args[0].number) else 0;
    const new_obj = try Object.create(it.arena, typedArrayProtoFor(it, elem));
    const c = try allocWithBuffer(it, new_obj, elem, length);
    if (c.isAbrupt()) return .{ .abrupt = c };
    return .{ .obj = new_obj };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Prototype methods (§23.2.3)
// ─────────────────────────────────────────────────────────────────────────────────────────────────

pub fn method(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const o = switch (try requireTA(it, this_val)) {
        .ta => |x| x,
        .abrupt => |c| return c,
    };
    const arg0: Value = if (args.len > 0) args[0] else .undefined;
    const arg1: Value = if (args.len > 1) args[1] else .undefined;
    const arg2: Value = if (args.len > 2) args[2] else .undefined;

    // Iterators (§23.2.3.6/.16/.32/.36) — don't require a non-detached buffer to CREATE.
    if (eql(u8, name, "values")) return makeIter(it, o, .value);
    if (eql(u8, name, "keys")) return makeIter(it, o, .key);
    if (eql(u8, name, "entries")) return makeIter(it, o, .entry);

    // §23.2.3 ValidateTypedArray for the rest: throw on a detached buffer up front.
    if (isDetached(o)) return it.throwError("TypeError", "Cannot operate on a detached buffer");
    const len = TA.of(o).length;

    if (eql(u8, name, "at")) return at(it, o, len, arg0);
    if (eql(u8, name, "fill")) return fill(it, o, len, args);
    if (eql(u8, name, "copyWithin")) return copyWithin(it, o, len, args);
    if (eql(u8, name, "every")) return iterTest(it, o, len, args, .every);
    if (eql(u8, name, "some")) return iterTest(it, o, len, args, .some);
    if (eql(u8, name, "forEach")) return forEach(it, o, len, args);
    if (eql(u8, name, "map")) return mapMethod(it, o, len, args);
    if (eql(u8, name, "filter")) return filter(it, o, len, args);
    if (eql(u8, name, "find")) return findFamily(it, o, len, args, .find);
    if (eql(u8, name, "findIndex")) return findFamily(it, o, len, args, .find_index);
    if (eql(u8, name, "findLast")) return findFamily(it, o, len, args, .find_last);
    if (eql(u8, name, "findLastIndex")) return findFamily(it, o, len, args, .find_last_index);
    if (eql(u8, name, "indexOf")) return indexOf(it, o, len, args, false);
    if (eql(u8, name, "lastIndexOf")) return indexOf(it, o, len, args, true);
    if (eql(u8, name, "includes")) return includes(it, o, len, args);
    if (eql(u8, name, "join")) return join(it, o, len, arg0);
    if (eql(u8, name, "reverse")) return reverse(it, o, len);
    if (eql(u8, name, "toReversed")) return toReversed(it, o, len);
    if (eql(u8, name, "reduce")) return reduce(it, o, len, args, false);
    if (eql(u8, name, "reduceRight")) return reduce(it, o, len, args, true);
    if (eql(u8, name, "slice")) return slice(it, o, len, arg0, arg1);
    if (eql(u8, name, "subarray")) return subarray(it, o, len, arg0, arg1);
    if (eql(u8, name, "set")) return setMethod(it, o, arg0, arg1);
    if (eql(u8, name, "sort")) return sort(it, o, len, arg0, false);
    if (eql(u8, name, "toSorted")) return sort(it, o, len, arg0, true);
    if (eql(u8, name, "with")) return withMethod(it, o, len, arg0, arg1);
    if (eql(u8, name, "toLocaleString")) return toLocaleString(it, o, len);
    _ = arg2;
    return it.throwError("TypeError", "unknown TypedArray method");
}

/// §23.2.3.6/.16/.32/.36 create a typed-array iterator (value / key / entry).
fn makeIter(it: *Interpreter, o: *Object, kind: object_mod.IterKind) EvalError!Completion {
    const iter = try Object.create(it.arena, it.iteratorProto());
    iter.iter = .{ .typed_array = o, .cursor = 0, .kind = kind };
    try @import("interp_collection.zig").installIteratorNext(it, iter);
    return .{ .normal = .{ .object = iter } };
}

/// §23.2.3.1 at ( index ) — relative index (negative counts from the end); OOB → undefined.
fn at(it: *Interpreter, o: *Object, len: usize, idx_v: Value) EvalError!Completion {
    const rc = try it.toIntegerOrInfinity(idx_v);
    if (rc.isAbrupt()) return rc;
    const rel = rc.normal.number;
    const k: f64 = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
    if (k < 0 or k >= @as(f64, @floatFromInt(len))) return .{ .normal = .undefined };
    return .{ .normal = try TA.of(o).get(it, @intFromFloat(k)) };
}

/// §23.2.3.9 fill ( value [ , start [ , end ] ] ) — coerce the value ONCE, then write [start,end).
fn fill(it: *Interpreter, o: *Object, len: usize, args: []const Value) EvalError!Completion {
    const value: Value = if (args.len > 0) args[0] else .undefined;
    // §23.2.3.9 step 3-4: coerce value to the content type up front (observable, once).
    const coerced = try coerceForElem(it, o.typed_array.?.elem, value);
    if (coerced.isAbrupt()) return coerced;
    const start = switch (try relIndex(it, if (args.len > 1) args[1] else .undefined, len, 0)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const end = switch (try relIndex(it, if (args.len > 2) args[2] else .undefined, len, len)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    // §23.2.3.9 step 12: re-validate (a coercion side effect may have detached the buffer).
    if (isDetached(o)) return it.throwError("TypeError", "Buffer detached during fill");
    const cur_len = TA.of(o).length;
    var i = start;
    while (i < end and i < cur_len) : (i += 1) {
        _ = try writeElemChecked(it, o, @floatFromInt(i), coerced.normal);
    }
    return .{ .normal = .{ .object = o } };
}

/// §23.2.3.5 copyWithin ( target, start [ , end ] ) — byte-wise intra-buffer copy with overlap handling.
fn copyWithin(it: *Interpreter, o: *Object, len: usize, args: []const Value) EvalError!Completion {
    const to = switch (try relIndex(it, if (args.len > 0) args[0] else .undefined, len, 0)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const from = switch (try relIndex(it, if (args.len > 1) args[1] else .undefined, len, 0)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const final = switch (try relIndex(it, if (args.len > 2) args[2] else .undefined, len, len)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    if (isDetached(o)) return it.throwError("TypeError", "Buffer detached during copyWithin");
    const ta = TA.of(o);
    // Clamp by BOTH endpoints against the (live-clamped) length so neither the source nor the
    // destination byte range can exceed the slice if the buffer shrank during the index coercions.
    const count = @min(final -| from, @min(ta.length -| to, ta.length -| from));
    if (count > 0) {
        const bpe = ta.elem.bytesPerElement();
        const bytes = ta.bytes.?;
        // §23.2.3.5 step 14: a byte-level memmove honouring overlap.
        std.mem.copyForwards(u8, bytes[to * bpe .. to * bpe + count * bpe], bytes[from * bpe .. from * bpe + count * bpe]);
    }
    return .{ .normal = .{ .object = o } };
}

const TestKind = enum { every, some };

/// §23.2.3.7 every / §23.2.3.34 some — predicate over each element.
fn iterTest(it: *Interpreter, o: *Object, len: usize, args: []const Value, kind: TestKind) EvalError!Completion {
    const cb = try requireCallback(it, args);
    if (cb.isAbrupt()) return cb;
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try TA.of(o).get(it, i);
        const rc = try it.callFunction(cb.normal.object, &.{ v, .{ .number = @floatFromInt(i) }, .{ .object = o } }, this_arg);
        if (rc.isAbrupt()) return rc;
        const t = ops.toBoolean(rc.normal);
        if (kind == .every and !t) return .{ .normal = .{ .boolean = false } };
        if (kind == .some and t) return .{ .normal = .{ .boolean = true } };
    }
    return .{ .normal = .{ .boolean = kind == .every } };
}

/// §23.2.3.12 forEach.
fn forEach(it: *Interpreter, o: *Object, len: usize, args: []const Value) EvalError!Completion {
    const cb = try requireCallback(it, args);
    if (cb.isAbrupt()) return cb;
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try TA.of(o).get(it, i);
        const rc = try it.callFunction(cb.normal.object, &.{ v, .{ .number = @floatFromInt(i) }, .{ .object = o } }, this_arg);
        if (rc.isAbrupt()) return rc;
    }
    return .{ .normal = .undefined };
}

/// §23.2.3.22 map — species-create a same-length typed array, write callback(v,i) into each slot.
fn mapMethod(it: *Interpreter, o: *Object, len: usize, args: []const Value) EvalError!Completion {
    const cb = try requireCallback(it, args);
    if (cb.isAbrupt()) return cb;
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    const created = switch (try speciesCreate(it, o, &.{.{ .number = @floatFromInt(len) }})) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try TA.of(o).get(it, i);
        const rc = try it.callFunction(cb.normal.object, &.{ v, .{ .number = @floatFromInt(i) }, .{ .object = o } }, this_arg);
        if (rc.isAbrupt()) return rc;
        if (try writeElemChecked(it, created, @floatFromInt(i), rc.normal)) |c| return c;
    }
    return .{ .normal = .{ .object = created } };
}

/// §23.2.3.10 filter — collect kept values, then species-create a typed array of that length.
fn filter(it: *Interpreter, o: *Object, len: usize, args: []const Value) EvalError!Completion {
    const cb = try requireCallback(it, args);
    if (cb.isAbrupt()) return cb;
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    var kept: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try TA.of(o).get(it, i);
        const rc = try it.callFunction(cb.normal.object, &.{ v, .{ .number = @floatFromInt(i) }, .{ .object = o } }, this_arg);
        if (rc.isAbrupt()) return rc;
        if (ops.toBoolean(rc.normal)) try kept.append(it.arena, v);
    }
    const created = switch (try speciesCreate(it, o, &.{.{ .number = @floatFromInt(kept.items.len) }})) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    for (kept.items, 0..) |v, j| {
        if (try writeElemChecked(it, created, @floatFromInt(j), v)) |c| return c;
    }
    return .{ .normal = .{ .object = created } };
}

const FindKind = enum { find, find_index, find_last, find_last_index };

/// §23.2.3.11/.13/.14/.15 find / findIndex / findLast / findLastIndex.
fn findFamily(it: *Interpreter, o: *Object, len: usize, args: []const Value, kind: FindKind) EvalError!Completion {
    const cb = try requireCallback(it, args);
    if (cb.isAbrupt()) return cb;
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    const reverse_dir = (kind == .find_last or kind == .find_last_index);
    var idx: usize = if (reverse_dir) len else 0;
    while (true) {
        if (reverse_dir) {
            if (idx == 0) break;
            idx -= 1;
        } else {
            if (idx >= len) break;
        }
        const i = idx;
        const v = try TA.of(o).get(it, i);
        const rc = try it.callFunction(cb.normal.object, &.{ v, .{ .number = @floatFromInt(i) }, .{ .object = o } }, this_arg);
        if (rc.isAbrupt()) return rc;
        if (ops.toBoolean(rc.normal)) {
            return switch (kind) {
                .find, .find_last => .{ .normal = v },
                .find_index, .find_last_index => .{ .normal = .{ .number = @floatFromInt(i) } },
            };
        }
        if (!reverse_dir) idx += 1;
    }
    return switch (kind) {
        .find, .find_last => .{ .normal = .undefined },
        .find_index, .find_last_index => .{ .normal = .{ .number = -1 } },
    };
}

/// §23.2.3.18 indexOf / §23.2.3.20 lastIndexOf — StrictEquals search; bigint values compared via the
/// element decode (so `1` never matches a bigint element). Detached short-circuits to -1.
fn indexOf(it: *Interpreter, o: *Object, len: usize, args: []const Value, last: bool) EvalError!Completion {
    if (len == 0) return .{ .normal = .{ .number = -1 } };
    const search: Value = if (args.len > 0) args[0] else .undefined;
    // §23.2.3.18 step 11: a search value of the wrong "type bucket" for the array can never match.
    // SAFETY: assigned in both branches of the immediately-following `if (!last)` before any read.
    var from: i64 = undefined;
    if (!last) {
        const fc = try it.toIntegerOrInfinity(if (args.len > 1) args[1] else .undefined);
        if (fc.isAbrupt()) return fc;
        var n = fc.normal.number;
        if (n >= @as(f64, @floatFromInt(len))) return .{ .normal = .{ .number = -1 } };
        if (n < 0) n = @max(0, @as(f64, @floatFromInt(len)) + n);
        from = @intFromFloat(n);
    } else {
        const fc = try it.toIntegerOrInfinity(if (args.len > 1) args[1] else .{ .number = @floatFromInt(len - 1) });
        if (fc.isAbrupt()) return fc;
        var n = fc.normal.number;
        if (args.len <= 1) n = @floatFromInt(len - 1);
        if (n < 0) n = @as(f64, @floatFromInt(len)) + n;
        if (n < 0) return .{ .normal = .{ .number = -1 } };
        if (n >= @as(f64, @floatFromInt(len))) n = @floatFromInt(len - 1);
        from = @intFromFloat(n);
    }
    if (!last) {
        var i: usize = @intCast(from);
        while (i < len) : (i += 1) {
            const v = try TA.of(o).get(it, i);
            if (ops.strictEquals(v, search)) return .{ .normal = .{ .number = @floatFromInt(i) } };
        }
    } else {
        var i: i64 = from;
        while (i >= 0) : (i -= 1) {
            const v = try TA.of(o).get(it, @intCast(i));
            if (ops.strictEquals(v, search)) return .{ .normal = .{ .number = @floatFromInt(i) } };
        }
    }
    return .{ .normal = .{ .number = -1 } };
}

/// §23.2.3.15 includes ( searchElement [ , fromIndex ] ) — SameValueZero search.
fn includes(it: *Interpreter, o: *Object, len: usize, args: []const Value) EvalError!Completion {
    if (len == 0) return .{ .normal = .{ .boolean = false } };
    const search: Value = if (args.len > 0) args[0] else .undefined;
    const fc = try it.toIntegerOrInfinity(if (args.len > 1) args[1] else .{ .number = 0 });
    if (fc.isAbrupt()) return fc;
    var n = fc.normal.number;
    if (n >= @as(f64, @floatFromInt(len))) return .{ .normal = .{ .boolean = false } };
    if (n < 0) n = @max(0, @as(f64, @floatFromInt(len)) + n);
    var i: usize = @intFromFloat(n);
    while (i < len) : (i += 1) {
        const v = try TA.of(o).get(it, i);
        if (ops.sameValueZero(v, search)) return .{ .normal = .{ .boolean = true } };
    }
    return .{ .normal = .{ .boolean = false } };
}

/// §23.2.3.17 join ( separator ) — ToString each element, joined by the separator (default ",").
fn join(it: *Interpreter, o: *Object, len: usize, sep_v: Value) EvalError!Completion {
    const sep: []const u8 = if (sep_v == .undefined) "," else try it.toString(sep_v);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try buf.appendSlice(it.arena, sep);
        const v = try TA.of(o).get(it, i);
        // Elements are always Number/BigInt (never undefined/null) for a live typed array.
        const s = try it.toString(v);
        try buf.appendSlice(it.arena, s);
    }
    return .{ .normal = .{ .string = buf.items } };
}

/// §23.2.3.33 reverse — in place.
fn reverse(it: *Interpreter, o: *Object, len: usize) EvalError!Completion {
    _ = it;
    const ta = TA.of(o);
    const bpe = ta.elem.bytesPerElement();
    const bytes = ta.bytes.?;
    if (len > 1) {
        var lo: usize = 0;
        var hi: usize = len - 1;
        while (lo < hi) : ({
            lo += 1;
            hi -= 1;
        }) {
            // swap element `lo` and element `hi` byte-wise.
            var k: usize = 0;
            while (k < bpe) : (k += 1) {
                const tmp = bytes[lo * bpe + k];
                bytes[lo * bpe + k] = bytes[hi * bpe + k];
                bytes[hi * bpe + k] = tmp;
            }
        }
    }
    return .{ .normal = .{ .object = o } };
}

/// §23.2.3.35 toReversed — a new typed array (same element type, via the default constructor) reversed.
fn toReversed(it: *Interpreter, o: *Object, len: usize) EvalError!Completion {
    const elem = o.typed_array.?.elem;
    const created = switch (try directCreate(it, elem, &.{.{ .number = @floatFromInt(len) }})) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try TA.of(o).get(it, len - 1 - i);
        _ = try writeElemChecked(it, created, @floatFromInt(i), v);
    }
    return .{ .normal = .{ .object = created } };
}

/// §23.2.3.26 reduce / §23.2.3.27 reduceRight.
fn reduce(it: *Interpreter, o: *Object, len: usize, args: []const Value, right: bool) EvalError!Completion {
    const cb = try requireCallback(it, args);
    if (cb.isAbrupt()) return cb;
    const has_init = args.len > 1;
    if (len == 0 and !has_init) return it.throwError("TypeError", "Reduce of empty array with no initial value");
    // SAFETY: when no init is provided, `acc` is set from the first visited element before its first
    // read (the `if (!started)` branch below); a 0-length array with no init already threw above.
    var acc: Value = if (has_init) args[1] else undefined;
    var started = has_init;
    var count: usize = 0;
    while (count < len) : (count += 1) {
        const i = if (right) len - 1 - count else count;
        const v = try TA.of(o).get(it, i);
        if (!started) {
            acc = v;
            started = true;
            continue;
        }
        const rc = try it.callFunction(cb.normal.object, &.{ acc, v, .{ .number = @floatFromInt(i) }, .{ .object = o } }, .undefined);
        if (rc.isAbrupt()) return rc;
        acc = rc.normal;
    }
    return .{ .normal = acc };
}

/// §23.2.3.29 slice ( start, end ) — species-create a typed array over [start,end). When the element
/// type matches, a fast byte copy; else element-by-element.
fn slice(it: *Interpreter, o: *Object, len: usize, start_v: Value, end_v: Value) EvalError!Completion {
    const start = switch (try relIndex(it, start_v, len, 0)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const end = switch (try relIndex(it, end_v, len, len)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const count = end -| start;
    const created = switch (try speciesCreate(it, o, &.{.{ .number = @floatFromInt(count) }})) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    if (count > 0) {
        if (isDetached(o)) return it.throwError("TypeError", "Buffer detached during slice");
        const src = TA.of(o);
        const dst = TA.of(created);
        if (src.elem == dst.elem) {
            const bpe = src.elem.bytesPerElement();
            // Clamp the copy to what BOTH live slices hold: the source may have shrunk during the index
            // coercions / speciesCreate (user `valueOf`/ctor), and a user species ctor can return a
            // shorter view. `copyForwards` is overlap-tolerant (the regions may alias the same bytes).
            const copy_elems = @min(@min(count, src.length -| start), dst.length);
            // Guard: when the source shrank to nothing, `start * bpe` may exceed the live len, so even a
            // zero-length `src.bytes[start*bpe..start*bpe]` slice would be out of range — skip entirely.
            if (copy_elems > 0)
                std.mem.copyForwards(u8, dst.bytes.?[0 .. copy_elems * bpe], src.bytes.?[start * bpe .. start * bpe + copy_elems * bpe]);
        } else {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const v = try src.get(it, start + i);
                if (try writeElemChecked(it, created, @floatFromInt(i), v)) |c| return c;
            }
        }
    }
    return .{ .normal = .{ .object = created } };
}

/// §23.2.3.30 subarray ( begin, end ) — a NEW VIEW sharing the buffer (no copy), species-created.
fn subarray(it: *Interpreter, o: *Object, len: usize, begin_v: Value, end_v: Value) EvalError!Completion {
    const ta = o.typed_array.?;
    const begin = switch (try relIndex(it, begin_v, len, 0)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const end = switch (try relIndex(it, end_v, len, len)) {
        .idx => |i| i,
        .abrupt => |c| return c,
    };
    const new_len = end -| begin;
    const bpe = ta.elem.bytesPerElement();
    const new_offset = ta.byte_offset + begin * bpe;
    // §23.2.3.30 step 16: species-create with (buffer, beginByteOffset, newLength).
    const created = switch (try speciesCreate(it, o, &.{
        .{ .object = ta.buffer },
        .{ .number = @floatFromInt(new_offset) },
        .{ .number = @floatFromInt(new_len) },
    })) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    return .{ .normal = .{ .object = created } };
}

/// §23.2.3.24 set ( source [ , offset ] ) — copy from a typed array OR an array-like into this view,
/// starting at `offset`. Bounds-checked (RangeError on overflow); content types must match for a
/// typed-array source.
fn setMethod(it: *Interpreter, o: *Object, source: Value, offset_v: Value) EvalError!Completion {
    // §23.2.3.24 step 3-4: offset = ToIntegerOrInfinity(offset); must be >= 0.
    const oc = try it.toIntegerOrInfinity(offset_v);
    if (oc.isAbrupt()) return oc;
    const off_n = oc.normal.number;
    if (off_n < 0) return it.throwError("RangeError", "Invalid set offset");
    if (isDetached(o)) return it.throwError("TypeError", "Buffer detached");
    const target_len = TA.of(o).length;
    // §23.2.3.24: an offset of +Infinity (or beyond 2^53) can never satisfy offset+srcLen<=targetLen,
    // so it is a RangeError; cap before the (panicking) float→int conversion.
    if (off_n > 9007199254740991.0) return it.throwError("RangeError", "set offset out of range");
    const offset: usize = @intFromFloat(off_n);

    if (source == .object and source.object.kind == .typed_array) {
        // §23.2.3.24.1 SetTypedArrayFromTypedArray.
        const src_obj = source.object;
        if (isDetached(src_obj)) return it.throwError("TypeError", "Source buffer detached");
        if (o.typed_array.?.elem.contentType() != src_obj.typed_array.?.elem.contentType()) {
            return it.throwError("TypeError", "Cannot mix BigInt and Number typed arrays in set");
        }
        const src = TA.of(src_obj);
        if (offset + src.length > target_len) return it.throwError("RangeError", "set source too long for target");
        // Snapshot the source elements first (source and target may share a buffer).
        const snap = try it.arena.alloc(Value, src.length);
        var i: usize = 0;
        while (i < src.length) : (i += 1) snap[i] = try src.get(it, i);
        for (snap, 0..) |v, j| _ = try writeElemChecked(it, o, @floatFromInt(offset + j), v);
        return .{ .normal = .undefined };
    }

    // §23.2.3.24.2 SetTypedArrayFromArrayLike.
    const src_obj = switch (try it.toObjectForArrayLike(source)) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    const src_len = switch (try it.lengthOfArrayLike(src_obj)) {
        .len => |l| l,
        .abrupt => |c| return c,
    };
    if (offset + src_len > target_len) return it.throwError("RangeError", "set source too long for target");
    var i: usize = 0;
    while (i < src_len) : (i += 1) {
        const key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
        const gc = try it.getProperty(.{ .object = src_obj }, key);
        if (gc.isAbrupt()) return gc;
        if (try writeElemChecked(it, o, @floatFromInt(offset + i), gc.normal)) |c| return c;
    }
    return .{ .normal = .undefined };
}

/// §23.2.3.32 sort / §23.2.3.34 toSorted — DEFAULT numeric compare (NOT lexicographic). With a
/// comparefn, calls it (must be callable); NaN sorts to the end for the default compare.
fn sort(it: *Interpreter, o: *Object, len: usize, comparefn: Value, to_sorted: bool) EvalError!Completion {
    var compare: ?*Object = null;
    if (comparefn != .undefined) {
        if (comparefn != .object or !interp.isCallable(comparefn.object)) {
            return it.throwError("TypeError", "TypedArray sort comparator is not callable");
        }
        compare = comparefn.object;
    }
    // Snapshot the current values.
    const vals = try it.arena.alloc(Value, len);
    {
        var i: usize = 0;
        while (i < len) : (i += 1) vals[i] = try TA.of(o).get(it, i);
    }
    // Insertion sort (stable, tolerant of a comparator with side effects / an abrupt completion).
    var i: usize = 1;
    while (i < len) : (i += 1) {
        const key = vals[i];
        var j: usize = i;
        while (j > 0) {
            const order = try sortCompare(it, compare, vals[j - 1], key);
            if (order.isAbrupt()) return order;
            if (order.normal.number <= 0) break;
            vals[j] = vals[j - 1];
            j -= 1;
        }
        vals[j] = key;
    }
    const dst = if (to_sorted) blk: {
        const created = switch (try directCreate(it, o.typed_array.?.elem, &.{.{ .number = @floatFromInt(len) }})) {
            .obj => |x| x,
            .abrupt => |c| return c,
        };
        break :blk created;
    } else o;
    // §23.2.3.32 step 6: a comparefn may have detached the buffer; write-back is a no-op if so.
    var k: usize = 0;
    while (k < len) : (k += 1) {
        if (try writeElemChecked(it, dst, @floatFromInt(k), vals[k])) |c| return c;
    }
    return .{ .normal = .{ .object = dst } };
}

/// One comparison for sort: a comparefn (return value ToNumber'd, NaN→0) or the default numeric order
/// (§23.2.3.32 CompareTypedArrayElements: numeric <, with +0/-0 and NaN handling).
fn sortCompare(it: *Interpreter, compare: ?*Object, a: Value, b: Value) EvalError!Completion {
    if (compare) |cf| {
        const rc = try it.callFunction(cf, &.{ a, b }, .undefined);
        if (rc.isAbrupt()) return rc;
        const nc = try it.toNumberThrowing(rc.normal);
        if (nc.isAbrupt()) return nc;
        var n = nc.normal.number;
        if (std.math.isNan(n)) n = 0;
        return .{ .normal = .{ .number = n } };
    }
    // Default: numeric compare. Both operands are the same content type (the array's own elements).
    if (a == .bigint and b == .bigint) {
        const n: f64 = switch (@import("bigint.zig").order(a.bigint, b.bigint)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
        return .{ .normal = .{ .number = n } };
    }
    const x = a.number;
    const y = b.number;
    // §23.2.3.32 CompareTypedArrayElements: NaN > everything; -0 < +0.
    if (std.math.isNan(x)) return .{ .normal = .{ .number = if (std.math.isNan(y)) 0 else 1 } };
    if (std.math.isNan(y)) return .{ .normal = .{ .number = -1 } };
    if (x < y) return .{ .normal = .{ .number = -1 } };
    if (x > y) return .{ .normal = .{ .number = 1 } };
    if (x == 0 and y == 0) {
        const sx = std.math.signbit(x);
        const sy = std.math.signbit(y);
        if (sx and !sy) return .{ .normal = .{ .number = -1 } };
        if (!sx and sy) return .{ .normal = .{ .number = 1 } };
    }
    return .{ .normal = .{ .number = 0 } };
}

/// §23.2.3.39 with ( index, value ) — a NEW typed array (default ctor) with element `index` replaced.
fn withMethod(it: *Interpreter, o: *Object, len: usize, index_v: Value, value: Value) EvalError!Completion {
    const rc = try it.toIntegerOrInfinity(index_v);
    if (rc.isAbrupt()) return rc;
    const rel = rc.normal.number;
    const actual: f64 = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
    if (actual < 0 or actual >= @as(f64, @floatFromInt(len))) {
        return it.throwError("RangeError", "Invalid index in TypedArray.prototype.with");
    }
    // §23.2.3.39 step 6: coerce the value to the content type BEFORE creating the result (observable).
    const coerced = try coerceForElem(it, o.typed_array.?.elem, value);
    if (coerced.isAbrupt()) return coerced;
    const created = switch (try directCreate(it, o.typed_array.?.elem, &.{.{ .number = @floatFromInt(len) }})) {
        .obj => |x| x,
        .abrupt => |c| return c,
    };
    const target: usize = @intFromFloat(actual);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = if (i == target) coerced.normal else try TA.of(o).get(it, i);
        _ = try writeElemChecked(it, created, @floatFromInt(i), v);
    }
    return .{ .normal = .{ .object = created } };
}

/// §23.2.3.31 toLocaleString — ToString each element joined by "," (M-subset: no locale formatting).
fn toLocaleString(it: *Interpreter, o: *Object, len: usize) EvalError!Completion {
    return join(it, o, len, .{ .string = "," });
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Small shared helpers
// ─────────────────────────────────────────────────────────────────────────────────────────────────

const IdxResult = union(enum) { idx: usize, abrupt: Completion };

/// Clamp a relative index argument into [0, len] per the §23.2.3 slice/fill/copyWithin pattern
/// (ToIntegerOrInfinity; negative counts from the end; out-of-range clamps).
fn relIndex(it: *Interpreter, v: Value, len: usize, dflt: usize) EvalError!IdxResult {
    if (v == .undefined) return .{ .idx = dflt };
    const rc = try it.toIntegerOrInfinity(v);
    if (rc.isAbrupt()) return .{ .abrupt = rc };
    const n = rc.normal.number;
    if (n < 0) {
        const k = @as(f64, @floatFromInt(len)) + n;
        return .{ .idx = if (k < 0) 0 else @intFromFloat(k) };
    }
    const fl: f64 = @floatFromInt(len);
    return .{ .idx = if (n > fl) len else @intFromFloat(n) };
}

/// Coerce `v` to the element content type (ToNumber / ToBigInt) WITHOUT writing — used where the spec
/// coerces once up front (fill / with). Returns the coerced Value (a Number or BigInt) or an abrupt.
fn coerceForElem(it: *Interpreter, elem: ElemType, v: Value) EvalError!Completion {
    if (elem.contentType() == .bigint) {
        return builtin_bigint.toBigIntPub(it, v);
    }
    return it.toNumberThrowing(v);
}

/// §23.2.3 step "if argList is empty or callback is not callable, throw" — validate the first arg.
fn requireCallback(it: *Interpreter, args: []const Value) EvalError!Completion {
    if (args.len == 0 or args[0] != .object or !interp.isCallable(args[0].object)) {
        return it.throwError("TypeError", "callback is not a function");
    }
    return .{ .normal = args[0] };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// Realm intrinsic lookups
// ─────────────────────────────────────────────────────────────────────────────────────────────────

/// %ArrayBuffer.prototype% — the [[Prototype]] for buffers created by typed-array allocation.
fn arrayBufferProto(it: *Interpreter) ?*Object {
    return it.globalProto("ArrayBuffer");
}

/// The concrete `<Type>Array.prototype` for `elem`, or null in a realm-less eval.
fn typedArrayProtoFor(it: *Interpreter, elem: ElemType) ?*Object {
    return it.globalProto(elem.constructorName());
}

/// The concrete `<Type>Array` constructor for `elem` (the §23.2.4.1 default constructor), or null.
fn defaultConstructor(it: *Interpreter, elem: ElemType) ?*Object {
    const g = it.globals orelse return null;
    const b = g.lookup(elem.constructorName()) orelse return null;
    return if (b.value == .object) b.value.object else null;
}

/// Read a well-known symbol (`"iterator"` / `"species"` / …) off the realm `Symbol` constructor.
fn wellKnownSymbol(it: *Interpreter, name: []const u8) ?*Symbol {
    const g = it.globals orelse return null;
    const b = g.lookup("Symbol") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get(name) orelse return null;
    return if (pv == .symbol) pv.symbol else null;
}
