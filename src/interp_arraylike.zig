//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const builtin_object = @import("builtin_object.zig");
const builtin_reflect = @import("builtin_reflect.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_property = @import("interp_property.zig");
const sutf16 = @import("string_utf16.zig");

const toNumber = ops.toNumber;
const toBoolean = ops.toBoolean;
const parseIndex = ops.parseIndex;
const numberToString = ops.numberToString;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const isConstructor = interpreter.isConstructor;

/// §7.3.12 HasProperty(arr, i) over the Array exotic + its prototype chain — used by the
/// iteration/search family's hole check (a deleted own index can still be "present" via
/// `Array.prototype[i]`, so it must be visited per §23.1.3.x's `HasProperty` step).
pub fn arrayHasPropertyChain(self: *Interpreter, arr: *Object, i: usize) bool {
    if (arr.arrayHas(i)) return true;
    // Walk the prototype chain (ordinary objects + array exotics + the key string map).
    const key = numberToString(self.arena, @floatFromInt(i)) catch return false;
    var proto: ?*Object = arr.prototype;
    while (proto) |p| {
        if (p.kind == .array and p.arrayHas(i)) return true;
        if (p.getProp(key) != null) return true;
        proto = p.prototype;
    }
    return false;
}

/// §7.3.12 HasProperty(O, ToString(i)) over an ARBITRARY object + its prototype chain — the
/// generic-array-like counterpart of `arrayHasPropertyChain`. An array exotic checks its dense /
/// sparse store first; every kind then falls back to the string-keyed chain walk.
pub fn hasIndexChain(self: *Interpreter, o: *Object, i: usize) bool {
    if (o.kind == .array and o.arrayHas(i)) return true;
    const key = numberToString(self.arena, @floatFromInt(i)) catch return false;
    var p: ?*Object = o;
    while (p) |obj| {
        if (obj.kind == .array and obj.arrayHas(i)) return true;
        // §10.4.3: a `new String(s)` / boxed-String wrapper exposes the canonical integer indices
        // [0, len) as own properties — HasProperty must report them (else the generic Array methods
        // see a hole and skip the character).
        if (obj.primitive) |prim| if (prim == .string) {
            if (obj.getProp(key) == null and sutf16.codeUnitAt(prim.string, i) != null) return true;
        };
        if (obj.getProp(key) != null) return true;
        p = obj.prototype;
    }
    return false;
}

/// §7.3.18 LengthOfArrayLike ( obj ) = ToLength(Get(obj, "length")). Clamped to [0, 2^53-1].
/// Throwing (a Symbol/BigInt length → TypeError via ToNumber). Returns the length, or the abrupt
/// completion to propagate. The Array exotic short-circuits to its tracked length.
pub fn lengthOfArrayLike(self: *Interpreter, o: *Object) EvalError!Interpreter.LenOrAbrupt {
    if (o.kind == .array) return .{ .len = o.arrayLen() };
    const lc = try self.getProperty(.{ .object = o }, "length");
    if (lc.isAbrupt()) return .{ .abrupt = lc };
    const nc = try self.toNumberV(lc.normal);
    if (nc.isAbrupt()) return .{ .abrupt = nc };
    const n = nc.normal.number;
    const max_len: f64 = 9007199254740991.0; // 2^53 - 1
    const len: usize = if (std.math.isNan(n) or n <= 0) 0 else if (n > max_len) @intFromFloat(max_len) else @intFromFloat(@trunc(n));
    return .{ .len = len };
}

/// §7.3.4 Set(O, key, v, true) for an arbitrary object — Throw=true, so a failed [[Set]] (a
/// getter-only accessor, a non-writable own data property, a new property on a non-extensible object,
/// or a read-only String-wrapper index/length) raises a TypeError rather than silently no-op'ing
/// (the in-place mutating Array methods rely on this). Emulates §10.1.9 OrdinarySet's success bit.
pub fn setKeyThrow(self: *Interpreter, o: *Object, key: []const u8, v: Value) EvalError!Completion {
    // A `new String(s)` wrapper: the canonical integer indices [0, len) and `length` are read-only,
    // non-configurable own slots (§10.4.3) → any [[Set]] is rejected.
    if (o.primitive) |p| if (p == .string) {
        if (std.mem.eql(u8, key, "length")) return self.throwError("TypeError", "Cannot assign to read only property 'length' of String");
        if (parseIndex(key)) |idx| if (idx < p.string.len) {
            return self.throwError("TypeError", "Cannot assign to read only String index");
        };
    };
    // §10.1.9.2 OrdinarySetWithOwnDescriptor — resolve the property on the chain.
    if (o.getProp(key)) |loc| {
        switch (loc.pv.payload) {
            .accessor => |a| {
                const setter = a.set orelse return self.throwError("TypeError", "Cannot set property with only a getter");
                const sc = try self.callFunction(setter, &.{v}, .{ .object = o });
                if (sc.isAbrupt()) return sc;
                return .{ .normal = .undefined };
            },
            .data => {
                // An OWN non-writable data property rejects; an INHERITED one is shadowed by a new own
                // property (subject to extensibility).
                if (o.properties.getPtr(key)) |own| {
                    if (own.payload == .data and !own.writable) {
                        return self.throwError("TypeError", "Cannot assign to read only property");
                    }
                    own.payload = .{ .data = v };
                    return .{ .normal = .undefined };
                }
                if (!o.extensible) return self.throwError("TypeError", "Cannot add property, object is not extensible");
                try o.set(key, v);
                return .{ .normal = .undefined };
            },
        }
    }
    // Absent everywhere: create iff extensible.
    if (!o.extensible) return self.throwError("TypeError", "Cannot add property, object is not extensible");
    try o.set(key, v);
    return .{ .normal = .undefined };
}

/// §7.3.4 Set(O, ToString(i), v, true) for an arbitrary object. Array exotic uses the element store.
pub fn setIndexThrow(self: *Interpreter, o: *Object, i: usize, v: Value) EvalError!Completion {
    if (o.kind == .array) return arraySetThrow(self, o, i, v);
    return self.setKeyThrow(o, try numberToString(self.arena, @floatFromInt(i)), v);
}

/// §7.3.5 Set(O, "length", n, true) for an arbitrary object (the mutating methods' final length set).
pub fn setLengthThrow(self: *Interpreter, o: *Object, n: usize) EvalError!Completion {
    if (o.kind == .array) return arraySetLenThrow(self, o, n);
    return self.setKeyThrow(o, "length", .{ .number = @floatFromInt(n) });
}

/// §7.3.10 DeletePropertyOrThrow(O, ToString(i)) for an arbitrary object — a non-configurable own
/// property (incl. a String-wrapper index) rejects → TypeError. Array exotic deletes a true hole.
pub fn deleteIndexThrow(self: *Interpreter, o: *Object, i: usize) EvalError!Completion {
    if (o.kind == .array) {
        if (o.array_frozen) return self.throwError("TypeError", "Cannot delete property of a frozen array");
        try o.arrayDelete(i);
        return .{ .normal = .undefined };
    }
    // A String-wrapper canonical index is non-configurable → DeletePropertyOrThrow rejects.
    if (o.primitive) |p| if (p == .string) {
        if (i < p.string.len) return self.throwError("TypeError", "Cannot delete read only String index");
    };
    const key = try numberToString(self.arena, @floatFromInt(i));
    const dc = try self.deleteProperty(.{ .object = o }, key);
    if (dc.isAbrupt()) return dc;
    if (dc.normal == .boolean and !dc.normal.boolean) {
        return self.throwError("TypeError", "Cannot delete property");
    }
    return .{ .normal = .undefined };
}

/// §7.1.18 ToObject ( argument ) restricted to the cases the Array.prototype methods meet: an object
/// passes through; `undefined`/`null` throw; a primitive boxes into the matching wrapper so its
/// indexed reads (notably a String's chars / length) are observable as own properties.
pub fn toObjectForArrayLike(self: *Interpreter, v: Value) EvalError!Interpreter.ObjOrAbrupt {
    switch (v) {
        .object => |o| return .{ .obj = o },
        .undefined, .null => return .{ .abrupt = try self.throwError("TypeError", "Array.prototype method called on null or undefined") },
        .string => |s| {
            const w = try Object.create(self.arena, self.globalProto("String"));
            w.primitive = .{ .string = s };
            return .{ .obj = w };
        },
        else => {
            // §7.1.18 ToObject: number / boolean / symbol / bigint box into the matching wrapper,
            // proto-linked to the realm's `<Wrapper>.prototype` (e.g. `Boolean.prototype`) so both
            // `ToObject(1).constructor === Number` AND inherited indexed props / `length` set on that
            // prototype are observable, as in the spec's ToObject(this).
            const proto: ?*Object = (switch (v) {
                .number => self.globalProto("Number"),
                .boolean => self.globalProto("Boolean"),
                .symbol => self.globalProto("Symbol"),
                .bigint => self.globalProto("BigInt"),
                else => null,
            }) orelse self.objectProto();
            const w = try Object.create(self.arena, proto);
            w.primitive = v;
            return .{ .obj = w };
        },
    }
}

/// Public [[Get]] wrapper for built-in modules (e.g. `Array.from` reading `.length` / indices of
/// an array-like). Same semantics as the internal `getProperty` (invokes getters, throws on
/// null/undefined base).
pub fn getProperty2(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
    return self.getProperty(base, key);
}

/// Public §20.1.3.6 Object.prototype.toString wrapper for built-in modules (Array.prototype.toString
/// fallback when the object's `join` is not callable).
pub fn objectPrototypeToString(self: *Interpreter, this_val: Value) EvalError!Completion {
    return builtin_object.objectToString(self, this_val);
}

/// §7.3.20 Invoke ( V, P, argumentsList ) = Call(? GetV(V, P), V, args). Used by
/// Array.prototype.toLocaleString (it invokes each element's own `toLocaleString`).
pub fn invokeMethod(self: *Interpreter, v: Value, name: []const u8, args: []const Value) EvalError!Completion {
    const mc = try self.getProperty(v, name);
    if (mc.isAbrupt()) return mc;
    if (mc.normal != .object or mc.normal.object.kind != .function) {
        return self.throwError("TypeError", "property is not a function");
    }
    return self.callFunction(mc.normal.object, args, v);
}

/// Does `value` expose a `[Symbol.iterator]` method (i.e. is it iterable)? Used by `Array.from` to
/// choose the iterable branch over the array-like branch. A primitive String is iterable too, but
/// the caller checks that separately.
pub fn isArrayFromIterable(self: *Interpreter, value: Value) EvalError!bool {
    const iter_sym = self.wellKnownIterator() orelse return false;
    const mc = try self.getSymbolProperty(value, iter_sym);
    if (mc.isAbrupt()) return false;
    return mc.normal == .object and mc.normal.object.kind == .function;
}

/// Public wrapper for `iterateToList` (drain an iterable into `out`). Used by `Array.from`.
pub fn iterateToListPub(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
    return self.iterateToList(value, out);
}

/// §23.1.2.1 Array.from iterable branch (steps 6.b–6.h): step the iterator, apply `map_fn` per
/// element AS WE GO, and CreateDataProperty onto `out` at the running index. An abrupt completion
/// from `next`/`map_fn` triggers IteratorClose then propagates — so an infinite iterator whose
/// mapFn throws on the first element terminates immediately (no draining → no OOM). On success
/// `out.array_length` is the count. Returns the abrupt completion if any, else normal/undefined.
pub fn arrayFromIterate(self: *Interpreter, items: Value, out: *Object, map_fn: ?*Object, this_arg: Value) EvalError!Completion {
    const git = try self.getIterator(items);
    const iterator = switch (git) {
        .abrupt => |c| return c,
        .iterator => |i| i,
    };
    var k: usize = 0;
    while (true) {
        try self.tick(); // a genuinely infinite iterable fails via the watchdog, never hangs
        const step = try self.iteratorStep(iterator);
        switch (step) {
            .abrupt => |c| return c,
            .done => return .{ .normal = .undefined },
            .value => |v| {
                var to_store = v;
                if (map_fn) |f| {
                    const r = try self.callFunction(f, &.{ v, .{ .number = @floatFromInt(k) } }, this_arg);
                    if (r.isAbrupt()) {
                        try self.iteratorClose(iterator); // §7.4.11 close on abrupt mapFn
                        return r;
                    }
                    to_store = r.normal;
                }
                const dc = try self.createDataPropertyOrThrow(out, k, to_store);
                if (dc.isAbrupt()) {
                    try self.iteratorClose(iterator); // §7.4.11 close on a failed CreateDataProperty
                    return dc;
                }
                k += 1;
            },
        }
    }
}

/// §10.4.2.3 ArraySpeciesCreate ( originalArray, length ) — the result-array factory used by
/// filter/map/concat/slice/splice/flat/flatMap. Steps:
///   1. originalArray is not an Array exotic → plain ArrayCreate(length) (no `constructor` read).
///   2. C = Get(originalArray, "constructor") — a poisoned getter propagates its abrupt completion.
///   3. C is an Object → C = Get(C, @@species); a null species is treated as undefined (poisoned
///      species getter propagates).
///   4. C undefined → plain ArrayCreate(length).
///   5. C is not a constructor (incl. a non-object `constructor` value) → TypeError.
///   6. else Construct(C, « length »).
/// Returns the result object as a Value, or the abrupt completion.
pub fn arraySpeciesCreate(self: *Interpreter, original: *Object, length: usize) EvalError!Completion {
    // §10.4.2.3 step 2: IsArray(originalArray) — false → plain array, constructor untouched.
    if (original.kind != .array) return self.newArray(length);
    // step 3: C = Get(originalArray, "constructor")  (own/inherited; getter may throw).
    const cc = try self.getProperty(.{ .object = original }, "constructor");
    if (cc.isAbrupt()) return cc;
    var c = cc.normal;
    // step 5: if Type(C) is Object, C = Get(C, @@species); a null result → undefined.
    if (c == .object) {
        if (self.wellKnownSpecies()) |sp| {
            const sc = try self.getSymbolProperty(c, sp);
            if (sc.isAbrupt()) return sc;
            c = sc.normal;
        } else {
            // realm-less eval: no species symbol → treat the object constructor as "use default".
            c = .undefined;
        }
        if (c == .null) c = .undefined;
    }
    // step 6: C undefined → plain ArrayCreate(length).
    if (c == .undefined) return self.newArray(length);
    // step 7: IsConstructor(C) is false → TypeError (covers a non-object `constructor` and a
    // non-constructor @@species).
    if (c != .object or !isConstructor(c.object)) {
        return self.throwError("TypeError", "ArraySpeciesCreate: constructor species is not a constructor");
    }
    // step 8: Construct(C, « length »).
    return self.construct(c.object, &.{.{ .number = @floatFromInt(length) }});
}

/// §10.4.2.2 ArrayCreate(length): a fresh plain Array exotic of [[Length]] `length` (no eager fill —
/// a length-only grow is sparse), proto-linked to %Array.prototype%. The default ArraySpeciesCreate
/// result. A length above 2^32-1 → RangeError (step 1).
pub fn newArray(self: *Interpreter, length: usize) EvalError!Completion {
    if (length > 4294967295) return self.throwError("RangeError", "Invalid array length");
    const a = try Object.createArray(self.arena, self.arrayProto());
    a.array_length = length;
    return .{ .normal = .{ .object = a } };
}

/// §23.1.2.1/.3 the `A` target for Array.from / Array.of: `IsConstructor(C) ? Construct(C, «len») :
/// ArrayCreate(len)`. `C` is the `this` value of the static call (so `Array.from.call(Ctor, …)` uses
/// `Ctor`). A non-constructor `this` (e.g. the plain `Array.from(…)` where `this` is the Array ctor,
/// or an arbitrary non-ctor receiver) → a plain Array. The result is populated by the caller via
/// CreateDataPropertyOrThrow, so a constructor that returns a non-extensible / locked object throws.
pub fn arrayCreateFromCtor(self: *Interpreter, this_val: Value, length: usize) EvalError!Completion {
    if (this_val == .object and isConstructor(this_val.object) and this_val.object.native != .array_ctor) {
        return self.construct(this_val.object, &.{.{ .number = @floatFromInt(length) }});
    }
    return self.newArray(length);
}

/// §7.3.7 CreateDataPropertyOrThrow ( O, P, V ) — define an own data property
/// `{ value:V, writable:true, enumerable:true, configurable:true }`, throwing a TypeError if the
/// definition is rejected. For an Array exotic at an integer index this is the array [[Set]] with
/// Throw=true: a frozen array (non-writable elements) or a non-extensible array gaining a NEW index
/// rejects → TypeError. For a generic object (a non-Array species result) it routes through
/// [[DefineOwnProperty]] so a configurable non-writable existing prop is redefined writable.
/// Returns `.normal = undefined` on success, or the abrupt `.thrown` completion (caller propagates).
pub fn createDataPropertyOrThrow(self: *Interpreter, target: *Object, index: usize, value: Value) EvalError!Completion {
    if (target.kind == .array) {
        // Throw=true array [[Set]]: reject a write to a frozen element or a new index on a
        // non-extensible array (independent of strict mode — the method always throws).
        if (target.array_frozen) return self.throwError("TypeError", "Cannot add property to a frozen array");
        if (!target.extensible and !target.arrayHas(index)) {
            return self.throwError("TypeError", "Cannot add property to a non-extensible array");
        }
        try target.arraySet(self.arena, index, value);
        // §7.3.5 CreateDataProperty overwrites with default attributes — drop any stale string-keyed
        // entry for this index (e.g. a non-writable index installed via Object.defineProperty on the
        // species result) so the index now reads as a writable/enumerable/configurable own property.
        if (target.properties.count() != 0) _ = target.properties.orderedRemove(numberToString(self.arena, @floatFromInt(index)) catch return error.OutOfMemory);
        return .{ .normal = .undefined };
    }
    // Generic object: §10.1.6 [[DefineOwnProperty]] with the data-property defaults.
    const key = try numberToString(self.arena, @floatFromInt(index));
    const ok = try target.defineProperty(key, .{
        .value = value,
        .has_value = true,
        .writable = true,
        .enumerable = true,
        .configurable = true,
    });
    if (!ok) return self.throwError("TypeError", "CreateDataPropertyOrThrow: defining the property failed");
    return .{ .normal = .undefined };
}

/// §10.4.2.4-style array element [[Set]] with Throw=true, used by the in-place mutating methods
/// (push/unshift/shift/splice/fill/copyWithin/reverse/sort). Like `createDataPropertyOrThrow` for an
/// array but tolerant of overwriting an existing index on an extensible array (the common case).
/// Returns `.normal = undefined` on success, or the abrupt `.thrown` completion.
pub fn arraySetThrow(self: *Interpreter, arr: *Object, index: usize, value: Value) EvalError!Completion {
    if (arr.array_frozen) return self.throwError("TypeError", "Cannot modify a frozen array");
    if (!arr.extensible and !arr.arrayHas(index)) {
        return self.throwError("TypeError", "Cannot add property to a non-extensible array");
    }
    try arr.arraySet(self.arena, index, value);
    return .{ .normal = .undefined };
}

/// §10.4.2.4 array [[Set]] of `length` with Throw=true — a non-writable `length` (frozen array, or
/// `defineProperty(arr,"length",{writable:false})`) rejects ANY length [[Set]], including one to the
/// SAME value (ArraySetLength step 17 returns false → Set with Throw=true throws). Matches V8: the
/// length Set the mutating methods always perform throws even when the value is unchanged.
pub fn arraySetLenThrow(self: *Interpreter, arr: *Object, n: usize) EvalError!Completion {
    if (!arr.array_length_writable) {
        return self.throwError("TypeError", "Cannot assign to read only property 'length' of array");
    }
    try arr.arraySetLen(n);
    return .{ .normal = .undefined };
}

/// §6.2.6 ToPropertyDescriptor — read a descriptor object's own `value`/`writable`/`get`/`set`/
/// `enumerable`/`configurable` fields into a `Descriptor` (each present-or-absent via HasProperty).
/// `get`/`set` must be callable or `undefined` (TypeError otherwise). Returns null+throw on error.
pub fn toPropertyDescriptor(self: *Interpreter, attrs: Value) EvalError!Interpreter.DescOrAbrupt {
    if (attrs != .object) return .{ .abrupt = (try self.throwError("TypeError", "Property description must be an object")) };
    const o = attrs.object;
    var d: object_mod.Descriptor = .{};
    if (o.getProp("enumerable")) |_| {
        const c = try self.getProperty(attrs, "enumerable");
        if (c.isAbrupt()) return .{ .abrupt = c };
        d.enumerable = toBoolean(c.normal);
    }
    if (o.getProp("configurable")) |_| {
        const c = try self.getProperty(attrs, "configurable");
        if (c.isAbrupt()) return .{ .abrupt = c };
        d.configurable = toBoolean(c.normal);
    }
    if (o.getProp("value")) |_| {
        const c = try self.getProperty(attrs, "value");
        if (c.isAbrupt()) return .{ .abrupt = c };
        d.value = c.normal;
        d.has_value = true;
    }
    if (o.getProp("writable")) |_| {
        const c = try self.getProperty(attrs, "writable");
        if (c.isAbrupt()) return .{ .abrupt = c };
        d.writable = toBoolean(c.normal);
    }
    if (o.getProp("get")) |_| {
        const c = try self.getProperty(attrs, "get");
        if (c.isAbrupt()) return .{ .abrupt = c };
        if (c.normal == .undefined) {
            d.get = @as(?*Object, null);
        } else if (c.normal == .object and c.normal.object.kind == .function) {
            d.get = c.normal.object;
        } else return .{ .abrupt = (try self.throwError("TypeError", "Getter must be a function")) };
    }
    if (o.getProp("set")) |_| {
        const c = try self.getProperty(attrs, "set");
        if (c.isAbrupt()) return .{ .abrupt = c };
        if (c.normal == .undefined) {
            d.set = @as(?*Object, null);
        } else if (c.normal == .object and c.normal.object.kind == .function) {
            d.set = c.normal.object;
        } else return .{ .abrupt = (try self.throwError("TypeError", "Setter must be a function")) };
    }
    if (d.isAccessor() and d.isData()) {
        return .{ .abrupt = (try self.throwError("TypeError", "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute")) };
    }
    return .{ .desc = d };
}

/// §7.3.23 own ENUMERABLE string keys of `value` — a thin wrapper kept on the Interpreter so JSON
/// and other built-ins reach the helper now living in builtin_object.
pub fn ownEnumerableKeys(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!?Completion {
    return builtin_object.ownEnumerableKeys(self, value, out);
}

/// §7.1.19 ToPropertyKey then ToString — a thin wrapper kept on the Interpreter so Object/Reflect
/// reach the helper now living in builtin_reflect.zig.
pub fn toPropertyKeyString(self: *Interpreter, key: Value) EvalError![]const u8 {
    return builtin_reflect.toPropertyKeyString(self, key);
}

/// §21.3.2.27 Math.random — the next xorshift64* draw mapped to [0,1). A fixed-seed PRNG (no host
/// entropy in this sandbox; the engine is deterministic). Uses the top 53 bits for a uniform double.
pub fn randomNext(self: *Interpreter) f64 {
    var s = self.rng_state;
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    self.rng_state = s;
    const bits: u64 = (s *% 0x2545F4914F6CDD1D) >> 11; // 53 significant bits
    return @as(f64, @floatFromInt(bits)) * (1.0 / 9007199254740992.0); // / 2^53
}

/// §7.3.12 HasProperty for a Value key (string or symbol) — proto-chain walk (the `in` semantics).
/// §7.3.12 HasProperty as a Completion (so a Proxy `has` trap that throws/revokes can propagate).
/// Use this wherever the result feeds a JS-observable operation (`in`, `Reflect.has`).
pub fn hasPropertyVC(self: *Interpreter, base: Value, key: Value) EvalError!Completion {
    return interp_property.hasPropertyVC(self, base, key);
}

pub fn hasPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!bool {
    return interp_property.hasPropertyV(self, base, key);
}

/// §7.3.18 CreateListFromArrayLike (§20.2.3.1 step 2): null/undefined → empty list; an Array →
/// its elements; any other object → its `0..length-1` indexed values (M-subset: array-likes via
/// `.length`); a non-object non-nullish argArray → TypeError.
pub fn createListFromArrayLike(self: *Interpreter, v: Value) EvalError!Interpreter.ListOrAbrupt {
    switch (v) {
        .undefined, .null => return .{ .list = &.{} },
        .object => |o| {
            // Fast path ONLY for a TRULY dense array: backing store == [0..length) with every
            // index an own data property. A sparse array / one with holes (e.g. `[1,,2]`, whose
            // gap spilled to `sparse`) must NOT short-circuit here — its `elements.items` omits
            // the holes, so it would drop arguments. Fall through to LengthOfArrayLike + Get,
            // which reads each hole index as `undefined` (CreateListFromArrayLike, §7.3.18).
            if (o.kind == .array and o.array_length == o.elements.items.len and
                (o.holes == null or o.holes.?.count() == 0) and
                (o.sparse == null or o.sparse.?.count() == 0))
                return .{ .list = o.elements.items };
            // Generic array-like: read `length` then index 0..length-1.
            const lc = try self.getProperty(v, "length");
            if (lc.isAbrupt()) return .{ .abrupt = lc };
            const n = toNumber(lc.normal);
            const len: usize = if (n > 0 and n < 1e9) @intFromFloat(n) else 0;
            const list = try self.arena.alloc(Value, len);
            for (0..len) |i| {
                const key = try numberToString(self.arena, @floatFromInt(i));
                const ec = try self.getProperty(v, key);
                if (ec.isAbrupt()) return .{ .abrupt = ec };
                list[i] = ec.normal;
            }
            return .{ .list = list };
        },
        else => return .{ .abrupt = (try self.throwError("TypeError", "CreateListFromArrayLike called on non-object")) },
    }
}
