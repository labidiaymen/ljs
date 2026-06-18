//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const tarray = @import("typed_array.zig");
const builtin_collection = @import("builtin_collection.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

const toBoolean = ops.toBoolean;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const isCallable = interpreter.isCallable;
const SetRecord = Interpreter.SetRecord;

/// §23.1.5.1 CreateArrayIterator — a fresh Array Iterator object (proto = %Object.prototype% in the
/// M-subset) carrying the array + cursor in its native `iter` slot, with a `next` method.
pub fn makeArrayIterator(self: *Interpreter, this_val: Value, kind: @import("object.zig").IterKind) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Array.prototype.values requires an object");
    const iter = try Object.create(self.arena, self.iteratorProto()); // §23.1.5.1 proto = %Iterator.prototype%
    iter.iter = .{ .array = this_val.object, .cursor = 0, .kind = kind };
    try installIteratorNext(self, iter);
    return .{ .normal = .{ .object = iter } };
}

/// §24.1.1.1 / §24.2.1.1 collection construction: attach a fresh `Collection` of the right kind to
/// `new_obj`, then §24.1.1.2 AddEntriesFromIterable — if the iterable arg is non-nullish, get the
/// instance's (possibly subclass-overridden) `set`/`add` adder and feed each iterated record to it.
pub fn initCollectionInstance(self: *Interpreter, native: object_mod.NativeId, new_obj: *Object, args: []const Value) EvalError!Completion {
    const kind: object_mod.CollectionKind = switch (native) {
        .map_ctor => .map,
        .set_ctor => .set,
        .weakmap_ctor => .weakmap,
        .weakset_ctor => .weakset,
        else => unreachable,
    };
    const coll = try self.arena.create(object_mod.Collection);
    coll.* = .{ .kind = kind };
    new_obj.collection = coll;

    const iterable: Value = if (args.len > 0) args[0] else .undefined;
    if (iterable == .undefined or iterable == .null) return .{ .normal = .undefined };

    // §24.1.1.2 step 2: adder = Get(target, "set"/"add"); must be callable.
    const is_keyed = (kind == .map or kind == .weakmap);
    const adder_name: []const u8 = if (is_keyed) "set" else "add";
    const ac = try self.getProperty(.{ .object = new_obj }, adder_name);
    if (ac.isAbrupt()) return ac;
    if (ac.normal != .object or !isCallable(ac.normal.object)) {
        return self.throwError("TypeError", "collection adder is not callable");
    }
    const adder = ac.normal.object;

    const itr: *Object = switch (try self.getIterator(iterable)) {
        .iterator => |x| x,
        .abrupt => |c| return c,
    };
    // §24.1.1.2 step 4: for each record, call the adder; an abrupt completion closes the iterator.
    while (true) {
        const step = try self.iteratorStep(itr);
        switch (step) {
            .done => break,
            .abrupt => |c| return c,
            .value => |v| {
                if (is_keyed) {
                    // §24.1.1.2 step 4.d: each Map entry must be an object with [0]/[1].
                    if (v != .object) {
                        const e = try self.throwError("TypeError", "Iterator value is not an entry object");
                        try self.iteratorClose(itr);
                        return e;
                    }
                    const k0 = try self.getProperty(v, "0");
                    if (k0.isAbrupt()) {
                        try self.iteratorClose(itr);
                        return k0;
                    }
                    const v1 = try self.getProperty(v, "1");
                    if (v1.isAbrupt()) {
                        try self.iteratorClose(itr);
                        return v1;
                    }
                    const r = try self.callFunction(adder, &.{ k0.normal, v1.normal }, .{ .object = new_obj });
                    if (r.isAbrupt()) {
                        try self.iteratorClose(itr);
                        return r;
                    }
                } else {
                    const r = try self.callFunction(adder, &.{v}, .{ .object = new_obj });
                    if (r.isAbrupt()) {
                        try self.iteratorClose(itr);
                        return r;
                    }
                }
            },
        }
    }
    return .{ .normal = .undefined };
}

/// §24.1.5.1 / §24.2.5.1 CreateMapIterator / CreateSetIterator — a fresh iterator object (proto =
/// %Object.prototype% in the M-subset) carrying the collection + cursor in its `iter` slot. Requires
/// `this` to be a Map/Set instance (not a Weak collection — those are not iterable).
pub fn makeCollectionIterator(self: *Interpreter, this_val: Value, kind: object_mod.IterKind, home: object_mod.CollectionKind) EvalError!Completion {
    if (this_val != .object or this_val.object.collection == null) {
        return self.throwError("TypeError", "method called on an incompatible receiver");
    }
    const c = this_val.object.collection.?;
    // Brand: the receiver must be the SAME collection kind the method lives on (a Map iterator on a
    // Set, or vice versa, throws). Weak collections have no iterators so they never match here.
    if (c.kind != home) {
        return self.throwError("TypeError", "method called on an incompatible receiver");
    }
    const iter = try Object.create(self.arena, self.iteratorProto()); // §24.1.5.1 proto = %Iterator.prototype%
    iter.iter = .{ .collection = this_val.object, .cursor = 0, .kind = kind };
    try installIteratorNext(self, iter);
    return .{ .normal = .{ .object = iter } };
}

/// §24.1.3.10 / §24.2.3.9 get size — the count of present entries. `native_name` carries the brand
/// ("map"/"set") so the Map getter rejects a Set receiver (distinct [[MapData]]/[[SetData]] slots).
pub fn collectionSize(self: *Interpreter, native_name: []const u8, this_val: Value) EvalError!Completion {
    const want: object_mod.CollectionKind = if (std.mem.eql(u8, native_name, "set")) .set else .map;
    if (this_val == .object) {
        if (this_val.object.collection) |c| {
            if (c.kind == want) return .{ .normal = .{ .number = @floatFromInt(c.size) } };
        }
    }
    return self.throwError("TypeError", "get size called on an incompatible receiver");
}

/// §24.2.1.2 GetSetRecord ( obj ) — validate the set-like and capture its size/has/keys.
pub fn getSetRecord(self: *Interpreter, obj: Value) EvalError!Interpreter.SetRecOrAbrupt {
    if (obj != .object) return .{ .abrupt = try self.throwError("TypeError", "argument is not an object") };
    const sc = try self.getProperty2(obj, "size");
    if (sc.isAbrupt()) return .{ .abrupt = sc };
    const nc = try self.toNumberV(sc.normal); // ToNumber(undefined) = NaN → TypeError below
    if (nc.isAbrupt()) return .{ .abrupt = nc };
    if (std.math.isNan(nc.normal.number)) return .{ .abrupt = try self.throwError("TypeError", "size is NaN") };
    const isc = try self.toIntegerOrInfinityPub(nc.normal);
    if (isc.isAbrupt()) return .{ .abrupt = isc };
    const int_size = isc.normal.number;
    if (int_size < 0) return .{ .abrupt = try self.throwError("RangeError", "size is negative") };
    const hc = try self.getProperty2(obj, "has");
    if (hc.isAbrupt()) return .{ .abrupt = hc };
    if (hc.normal != .object or !isCallable(hc.normal.object)) return .{ .abrupt = try self.throwError("TypeError", "has is not callable") };
    const kc = try self.getProperty2(obj, "keys");
    if (kc.isAbrupt()) return .{ .abrupt = kc };
    if (kc.normal != .object or !isCallable(kc.normal.object)) return .{ .abrupt = try self.throwError("TypeError", "keys is not callable") };
    return .{ .rec = .{ .obj = obj, .size = int_size, .has = hc.normal.object, .keys = kc.normal.object } };
}

/// %Set.prototype% intrinsic (for the result of the set-algebra methods). Null in a realm-less eval.
pub fn setProto(self: *Interpreter) ?*Object {
    const g = self.globals orelse return null;
    const b = g.lookup("Set") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get("prototype") orelse return null;
    return if (pv == .object) pv.object else null;
}

/// A fresh empty Set instance (proto = %Set.prototype%, kind=set) — the result container.
pub fn newSetInstance(self: *Interpreter) EvalError!*Object {
    const o = try Object.create(self.arena, setProto(self));
    const coll = try self.arena.create(object_mod.Collection);
    coll.* = .{ .kind = .set };
    o.collection = coll;
    return o;
}

/// A new Set seeded with a SNAPSHOT of `src`'s present elements (in insertion order) — the
/// `resultSetData ← copy of O.[[SetData]]` step shared by union/difference/symmetricDifference.
pub fn cloneSet(self: *Interpreter, src: *object_mod.Collection) EvalError!*Object {
    const o = try newSetInstance(self);
    for (src.entries.items) |e| {
        if (e.present) try builtin_collection.addElement(self, o.collection.?, e.key);
    }
    return o;
}

/// Call `other.keys()` and require an object result — the iterator for the set-algebra walks.
pub fn setRecordKeysIter(self: *Interpreter, rec: SetRecord) EvalError!Interpreter.IterObjOrAbrupt {
    const kc = try self.callFunction(rec.keys, &.{}, rec.obj);
    if (kc.isAbrupt()) return .{ .abrupt = kc };
    if (kc.normal != .object) return .{ .abrupt = try self.throwError("TypeError", "keys() did not return an object") };
    return .{ .iter = kc.normal.object };
}

/// §24.2.3 union/intersection/difference/symmetricDifference/isSubsetOf/isSupersetOf/isDisjointFrom.
/// `this_coll` is the already-brand-checked Set; `args[0]` is the set-like `other`.
pub fn setAlgebra(self: *Interpreter, name: []const u8, this_coll: *object_mod.Collection, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const other: Value = if (args.len > 0) args[0] else .undefined;
    const rec = switch (try getSetRecord(self, other)) {
        .rec => |r| r,
        .abrupt => |c| return c,
    };
    const this_size: f64 = @floatFromInt(this_coll.size);

    if (eql(u8, name, "union")) {
        // §24.2.3.x: result = clone(O); add each of other's keys.
        const result = try cloneSet(self, this_coll);
        const iter = switch (try setRecordKeysIter(self, rec)) {
            .iter => |x| x,
            .abrupt => |c| return c,
        };
        while (true) {
            switch (try self.iteratorStep(iter)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| try builtin_collection.addElement(self, result.collection.?, v),
            }
        }
        return .{ .normal = .{ .object = result } };
    }

    if (eql(u8, name, "intersection")) {
        const result = try newSetInstance(self);
        if (this_size <= rec.size) {
            var i: usize = 0;
            while (i < this_coll.entries.items.len) : (i += 1) {
                if (!this_coll.entries.items[i].present) continue;
                const e = this_coll.entries.items[i].key;
                const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                if (hc.isAbrupt()) return hc;
                if (toBoolean(hc.normal) and builtin_collection.contains(this_coll, e)) {
                    try builtin_collection.addElement(self, result.collection.?, e);
                }
            }
        } else {
            const iter = switch (try setRecordKeysIter(self, rec)) {
                .iter => |x| x,
                .abrupt => |c| return c,
            };
            while (true) {
                switch (try self.iteratorStep(iter)) {
                    .done => break,
                    .abrupt => |c| return c,
                    .value => |v| if (builtin_collection.contains(this_coll, v)) try builtin_collection.addElement(self, result.collection.?, v),
                }
            }
        }
        return .{ .normal = .{ .object = result } };
    }

    if (eql(u8, name, "difference")) {
        const result = try cloneSet(self, this_coll);
        if (this_size <= rec.size) {
            var i: usize = 0;
            while (i < this_coll.entries.items.len) : (i += 1) {
                if (!this_coll.entries.items[i].present) continue;
                const e = this_coll.entries.items[i].key;
                const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                if (hc.isAbrupt()) return hc;
                if (toBoolean(hc.normal)) builtin_collection.removeElement(result.collection.?, e);
            }
        } else {
            const iter = switch (try setRecordKeysIter(self, rec)) {
                .iter => |x| x,
                .abrupt => |c| return c,
            };
            while (true) {
                switch (try self.iteratorStep(iter)) {
                    .done => break,
                    .abrupt => |c| return c,
                    .value => |v| builtin_collection.removeElement(result.collection.?, v),
                }
            }
        }
        return .{ .normal = .{ .object = result } };
    }

    if (eql(u8, name, "symmetricDifference")) {
        const result = try cloneSet(self, this_coll);
        const iter = switch (try setRecordKeysIter(self, rec)) {
            .iter => |x| x,
            .abrupt => |c| return c,
        };
        while (true) {
            switch (try self.iteratorStep(iter)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| {
                    // In O → exclude (remove from result); not in O → include (add).
                    if (builtin_collection.contains(this_coll, v)) {
                        builtin_collection.removeElement(result.collection.?, v);
                    } else {
                        try builtin_collection.addElement(self, result.collection.?, v);
                    }
                },
            }
        }
        return .{ .normal = .{ .object = result } };
    }

    if (eql(u8, name, "isSubsetOf")) {
        if (this_size > rec.size) return .{ .normal = .{ .boolean = false } };
        var i: usize = 0;
        while (i < this_coll.entries.items.len) : (i += 1) {
            if (!this_coll.entries.items[i].present) continue;
            const e = this_coll.entries.items[i].key;
            const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
            if (hc.isAbrupt()) return hc;
            if (!toBoolean(hc.normal)) return .{ .normal = .{ .boolean = false } };
        }
        return .{ .normal = .{ .boolean = true } };
    }

    if (eql(u8, name, "isSupersetOf")) {
        if (this_size < rec.size) return .{ .normal = .{ .boolean = false } };
        const iter = switch (try setRecordKeysIter(self, rec)) {
            .iter => |x| x,
            .abrupt => |c| return c,
        };
        while (true) {
            switch (try self.iteratorStep(iter)) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| if (!builtin_collection.contains(this_coll, v)) {
                    try self.iteratorClose(iter); // §24.2.3 IteratorClose(_, false)
                    return .{ .normal = .{ .boolean = false } };
                },
            }
        }
        return .{ .normal = .{ .boolean = true } };
    }

    if (eql(u8, name, "isDisjointFrom")) {
        if (this_size <= rec.size) {
            var i: usize = 0;
            while (i < this_coll.entries.items.len) : (i += 1) {
                if (!this_coll.entries.items[i].present) continue;
                const e = this_coll.entries.items[i].key;
                const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                if (hc.isAbrupt()) return hc;
                if (toBoolean(hc.normal)) return .{ .normal = .{ .boolean = false } };
            }
        } else {
            const iter = switch (try setRecordKeysIter(self, rec)) {
                .iter => |x| x,
                .abrupt => |c| return c,
            };
            while (true) {
                switch (try self.iteratorStep(iter)) {
                    .done => break,
                    .abrupt => |c| return c,
                    .value => |v| if (builtin_collection.contains(this_coll, v)) {
                        try self.iteratorClose(iter);
                        return .{ .normal = .{ .boolean = false } };
                    },
                }
            }
        }
        return .{ .normal = .{ .boolean = true } };
    }

    unreachable;
}

/// §22.1.5.1 CreateStringIterator — a fresh String Iterator object over the primitive string's
/// code units (M-subset: byte-at-a-time, matching the engine's String indexing model).
pub fn makeStringIterator(self: *Interpreter, this_val: Value) EvalError!Completion {
    const s: []const u8 = switch (this_val) {
        .string => |str| str,
        else => return self.throwError("TypeError", "String.prototype[Symbol.iterator] requires a string"),
    };
    const iter = try Object.create(self.arena, self.iteratorProto()); // §22.1.5.1 proto = %Iterator.prototype%
    iter.iter = .{ .string = s, .cursor = 0 };
    try installIteratorNext(self, iter);
    return .{ .normal = .{ .object = iter } };
}

/// Install the `next` native (non-enumerable) on a freshly created native iterator object. (The
/// M-subset puts `next` directly on the iterator; the real %ArrayIteratorPrototype% is deferred.)
pub fn installIteratorNext(self: *Interpreter, iter: *Object) EvalError!void {
    const next_fn = try Object.createNative(self.arena, .iterator_next, "next");
    next_fn.prototype = self.functionProto();
    try iter.defineData("next", .{ .object = next_fn }, true, false, true);
    // §27.1.2.1 %IteratorPrototype%[Symbol.iterator]() returns `this` — so the iterator object is
    // itself iterable (`for (x of arr.entries())`, `[...arr.keys()]`). Reuses the return-`this`
    // native. Keyed by the realm's well-known Symbol.iterator (absent only in a realm-less eval).
    if (self.wellKnownIterator()) |iter_sym| {
        const self_fn = try Object.createNative(self.arena, .generator_iterator, "[Symbol.iterator]");
        self_fn.prototype = self.functionProto();
        try iter.defineSymbolData(iter_sym, .{ .object = self_fn }, true, false, true);
    }
}

/// §23.1.5.2.1 / §22.1.5.2.1 %…IteratorPrototype%.next — advance the native iterator and return a
/// fresh `{ value, done }` IteratorResult object. Reads/advances the `iter` slot; `{value:undefined,
/// done:true}` once exhausted.
pub fn iteratorNext(self: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object or this_val.object.iter == null) {
        return self.throwError("TypeError", "next called on a non-iterator");
    }
    const st = &this_val.object.iter.?;
    var value: Value = .undefined;
    var done = true;
    if (st.collection) |cobj| {
        // §24.1.5.2 / §24.2.5.2: advance over the backing entries, SKIPPING tombstones; yield
        // key / value / [key,value] per the iterator kind. Entries added since creation are seen.
        const c = cobj.collection.?;
        while (st.cursor < c.entries.items.len) {
            const e = c.entries.items[st.cursor];
            st.cursor += 1;
            if (!e.present) continue;
            done = false;
            value = switch (st.kind) {
                .value => e.value,
                .key => e.key,
                .entry => blk: { // [key, value] pair (for a Set, key === value)
                    const pair = try Object.createArray(self.arena, self.arrayProto());
                    try pair.elements.append(self.arena, e.key);
                    try pair.elements.append(self.arena, e.value);
                    pair.array_length = 2;
                    break :blk .{ .object = pair };
                },
            };
            break;
        }
        // §24.1.5.2 step 11.b: once the iterator runs off the end it is COMPLETE — null the backing
        // link so entries added AFTER exhaustion are not resurrected by a later `next()`.
        if (done) st.collection = null;
    } else if (st.array) |arr| {
        if (st.cursor < arr.arrayLen()) {
            const idx = st.cursor;
            value = switch (st.kind) {
                .value => arr.arrayGet(idx),
                .key => .{ .number = @floatFromInt(idx) },
                .entry => blk: { // [index, value] pair (§23.1.5.2.1)
                    const pair = try Object.createArray(self.arena, self.arrayProto());
                    try pair.elements.append(self.arena, .{ .number = @floatFromInt(idx) });
                    try pair.elements.append(self.arena, arr.arrayGet(idx));
                    break :blk .{ .object = pair };
                },
            };
            st.cursor += 1;
            done = false;
        }
    } else if (st.typed_array) |ta_obj| {
        // §23.2.5.1 CreateArrayIterator over an integer-indexed exotic. Read live: a detached buffer
        // (or a cursor past the current length) ends the iteration; element access uses the codec.
        const ta = ta_obj.typed_array.?;
        const buf = ta.buffer.array_buffer;
        const len: usize = if (buf == null or buf.?.detached) 0 else ta.array_length;
        if (st.cursor < len) {
            const idx = st.cursor;
            const elem_v = try tarray.getElement(ta.elem, buf.?.bytes[ta.byte_offset..], idx, self.arena);
            value = switch (st.kind) {
                .value => elem_v,
                .key => .{ .number = @floatFromInt(idx) },
                .entry => blk: {
                    const pair = try Object.createArray(self.arena, self.arrayProto());
                    try pair.elements.append(self.arena, .{ .number = @floatFromInt(idx) });
                    try pair.elements.append(self.arena, elem_v);
                    pair.array_length = 2;
                    break :blk .{ .object = pair };
                },
            };
            st.cursor += 1;
            done = false;
        }
    } else if (st.string) |s| {
        if (st.cursor < s.len) {
            value = .{ .string = s[st.cursor .. st.cursor + 1] };
            st.cursor += 1;
            done = false;
        }
    }
    const result = try Object.create(self.arena, self.objectProto());
    try result.set("value", value);
    try result.set("done", .{ .boolean = done });
    return .{ .normal = .{ .object = result } };
}
