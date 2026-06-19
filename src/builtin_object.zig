//! §20.1 Object — the constructor's static reflection (defineProperty/defineProperties/keys/values/
//! entries/assign/create/freeze/seal/getOwnPropertyDescriptor(s)/getPrototypeOf/setPrototypeOf/is/
//! fromEntries/hasOwn/groupBy/getOwnPropertyNames/getOwnPropertySymbols), the Object.prototype methods
//! (toString/hasOwnProperty/propertyIsEnumerable/isPrototypeOf/__proto__/§B.2.2 legacy accessors), and
//! the §6.2.6 descriptor helpers. Dispatched from the interpreter's `callNative`; lives in its own file
//! so the interpreter stays the evaluator (mirrors `builtin_array.zig` etc.).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");
const object_mod = @import("object.zig");
const proxy = @import("builtin_proxy.zig");
const Object = object_mod.Object;

const Symbol = @import("value.zig").Symbol;
const parseIndex = ops.parseIndex;
const numberToString = ops.numberToString;
const toNumber = ops.toNumber;
const isCallable = interp.isCallable;

pub fn objectDefineProperty(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o != .object) return it.throwError("TypeError", "Object.defineProperty called on non-object");
    // §20.1.2.4 step 2: ToPropertyKey(P) BEFORE step 3 ToPropertyDescriptor(Attributes).
    const pk = try it.toPropertyKey(if (args.len > 1) args[1] else .undefined);
    if (pk.isAbrupt()) return pk.completion;
    const sym_key: ?*Symbol = pk.symbol;
    const str_key: []const u8 = pk.key;
    const r = try it.toPropertyDescriptor(if (args.len > 2) args[2] else .undefined);
    switch (r) {
        .abrupt => |c| return c,
        .desc => |d| {
            if (o.object.proxy != null) { // §10.5.6 [[DefineOwnProperty]] via the trap
                const dr = if (sym_key) |sym|
                    try it.ordinaryDefineOwnPropertySymbol(o.object, sym, d)
                else
                    try it.ordinaryDefineOwnProperty(o.object, str_key, d);
                switch (dr) {
                    .ok => |ok| if (!ok) return it.throwError("TypeError", "Cannot redefine property"),
                    .abrupt => |c| return c,
                }
                return .{ .normal = o };
            }
            if (sym_key) |sym| {
                const ok = try o.object.defineSymbolProperty(sym, d);
                if (!ok) return it.throwError("TypeError", "Cannot redefine property");
                return .{ .normal = o };
            }
            // §10.4.2.1 Array exotic [[DefineOwnProperty]] — `length` is synthetic (the real value
            // lives in `array_length`, with a separate `[[Writable]]`), so it needs the ArraySetLength
            // path; an integer index writes the element store (and grows [[Length]]) via arrayDefineIndex.
            if (o.object.kind == .array) {
                if (std.mem.eql(u8, str_key, "length")) {
                    const adc = try arrayDefineLength(it, o.object, d);
                    if (adc.isAbrupt()) return adc;
                    return .{ .normal = o };
                }
                if (arrayIndex(str_key)) |i| {
                    const adc = try arrayDefineIndex(it, o.object, i, str_key, d);
                    if (adc.isAbrupt()) return adc;
                    return .{ .normal = o };
                }
            }
            const ok = try o.object.defineProperty(str_key, d);
            if (!ok) return it.throwError("TypeError", "Cannot redefine property");
            // §10.4.4.2: keep a MAPPED arguments index consistent with its [[ParameterMap]] — a present
            // value writes the live parameter; the index leaves the map once it becomes an accessor or a
            // non-writable data property (so it stops aliasing the parameter thereafter).
            if (o.object.mapped_params) |mp| {
                if (parseIndex(str_key)) |i| if (i < mp.names.len and mp.names[i].len > 0) {
                    if (d.isAccessor()) {
                        mp.names[i] = "";
                    } else {
                        if (d.value) |v| {
                            if (mp.env.lookupLocal(mp.names[i])) |b| b.value = v;
                        }
                        if (d.writable) |w| {
                            if (!w) mp.names[i] = "";
                        }
                    }
                };
            }
            return .{ .normal = o };
        },
    }
}

/// §10.4.2.4 ArraySetLength applied to a [[DefineOwnProperty]] on an array's `length`. M-subset:
/// validate a present `value` (ToUint32, RangeError on a non-uint32), reject a writability UPGRADE
/// on a non-writable length, apply a length change (rejected if non-writable + a different value),
/// and record the resulting [[Writable]]. An accessor descriptor for `length` → reject.
pub fn arrayDefineLength(it: *Interpreter, arr: *Object, d: object_mod.Descriptor) EvalError!Completion {
    if (d.isAccessor()) return it.throwError("TypeError", "Cannot redefine array length as an accessor");
    if (d.enumerable) |e| if (e) return it.throwError("TypeError", "Cannot make array length enumerable");
    if (d.configurable) |c| if (c) return it.throwError("TypeError", "Cannot make array length configurable");
    // A length value change is gated by the CURRENT writability.
    if (d.has_value) {
        const n = toNumber(d.value.?);
        if (std.math.isNan(n) or n < 0 or n > 4294967295.0 or n != @floor(n)) {
            return it.throwError("RangeError", "Invalid array length");
        }
        const new_len: usize = @intFromFloat(n);
        if (new_len != arr.arrayLen() and !arr.array_length_writable) {
            return it.throwError("TypeError", "Cannot assign to read only property 'length'");
        }
        try arr.arraySetLen(new_len);
    }
    // §10.4.2.4 step 17: a non-writable length cannot be made writable again.
    if (d.writable) |w| {
        if (w and !arr.array_length_writable) return it.throwError("TypeError", "Cannot redefine non-writable array length as writable");
        arr.array_length_writable = w;
    }
    return .{ .normal = .undefined };
}

/// §10.4.2 IsArrayIndex — a canonical numeric string key `< 2^32-1`. Stricter than `parseIndex`:
/// it rejects non-canonical forms (leading zeros, etc.) and the max-uint32 sentinel (which is an
/// ordinary property, never an element). Returns the index or null.
pub fn arrayIndex(key: []const u8) ?usize {
    const i = parseIndex(key) orelse return null;
    if (i >= 4294967295) return null; // 2^32-1 is not an array index
    // canonical: ToString(i) must equal key (rejects "01", "+1", " 1", …)
    var buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return null;
    if (!std.mem.eql(u8, s, key)) return null;
    return i;
}

/// §10.4.2.1 Array exotic [[DefineOwnProperty]] for an integer index P. Implements ArraySetLength's
/// sibling: validate against the current element (via ValidateAndApply on a synthetic descriptor for
/// the existing slot), grow [[Length]] (rejecting when length is non-writable and P ≥ length), and
/// write the value to the dense/sparse element store. The M-subset element store represents the
/// default index attributes (writable/enumerable/configurable = true); a descriptor that would make
/// the index non-writable / non-configurable / an accessor is recorded so a frozen array's elements
/// stay non-writable, but per-index attribute *divergence* beyond the global `array_frozen` flag is
/// approximated. Returns abrupt (TypeError) when the (re)definition must be rejected.
pub fn arrayDefineIndex(it: *Interpreter, arr: *Object, i: usize, key: []const u8, d: object_mod.Descriptor) EvalError!Completion {
    // An index may currently live in the dense element store (default attributes, or non-writable when
    // the array is frozen) OR in the ordinary property map (a prior non-default / accessor define). These
    // two stores are mutually exclusive for a given index; resolve which one holds it.
    const in_map: ?object_mod.PropertyValue = arr.properties.get(key);
    const in_dense = arr.arrayHas(i);
    const present = in_map != null or in_dense;
    const len = arr.arrayLen();

    // §10.4.2.1 step 3.b: a new index at/after a non-writable length is rejected.
    if (!present and i >= len and !arr.array_length_writable) {
        return it.throwError("TypeError", "Cannot add array index past a non-writable length");
    }
    // §10.1.6.3 step 2.a: a new index on a non-extensible array is rejected.
    if (!present and !arr.extensible) {
        return it.throwError("TypeError", "Cannot define property, object is not extensible");
    }

    // §10.1.6.3 ValidateAndApplyPropertyDescriptor against the current index descriptor.
    if (in_map != null) {
        // The map holds the full current attribute set — delegate to the shared validator + merge.
        const ok = try arr.defineProperty(key, d);
        if (!ok) return it.throwError("TypeError", "Cannot redefine property");
        // Keep [[Length]] in sync (the index was already counted, but be defensive on grow).
        if (i + 1 > arr.array_length) arr.array_length = i + 1;
        return .{ .normal = .undefined };
    }
    if (in_dense) {
        // A dense slot is a writable/enumerable/configurable data property — unless the array is frozen
        // (then its elements are non-writable + non-configurable). §10.1.6.3 redefinition guards.
        const cur_writable = !arr.array_frozen;
        const cur_configurable = !arr.array_frozen;
        const cur_value = arr.arrayGet(i);
        if (!cur_configurable) {
            if (d.configurable orelse false) return it.throwError("TypeError", "Cannot redefine property");
            if (d.enumerable) |e| if (!e) return it.throwError("TypeError", "Cannot redefine property");
            if (d.isAccessor()) return it.throwError("TypeError", "Cannot redefine property");
            if (!cur_writable) {
                if (d.writable orelse false) return it.throwError("TypeError", "Cannot redefine property");
                if (d.has_value) {
                    if (!ops.sameValue(cur_value, d.value.?)) return it.throwError("TypeError", "Cannot redefine property");
                }
            }
        }
    }

    // §6.2.6.1 representable by the dense element store iff a data descriptor whose (merged) attributes
    // are the element-store defaults (writable/enumerable/configurable = true) on a non-frozen array.
    const wants_default =
        !d.isAccessor() and
        (d.writable orelse true) and
        (d.enumerable orelse true) and
        (d.configurable orelse true) and
        !arr.array_frozen;

    if (wants_default) {
        const v: Value = if (d.has_value) d.value.? else if (in_dense) arr.arrayGet(i) else .undefined;
        try arr.arraySet(it.arena, i, v);
        if (i + 1 > arr.array_length) arr.array_length = i + 1;
        return .{ .normal = .undefined };
    }

    // Non-default attributes / accessor: store in the ordinary property map so getOwnPropertyDescriptor,
    // Object.keys (enumerability), and integrity reflect the requested attributes. The dense store cannot
    // express per-index attributes, so the index lives ONLY in the map here (it is not in the dense store:
    // a prior dense slot can't coexist because the validation above ran on the dense descriptor and any
    // value mismatch is a configurable redefinition that supersedes it). `key` is the arena-owned
    // canonical key string the caller computed (the property map stores the slice as-is).
    const ok = try arr.defineProperty(key, d);
    if (!ok) return it.throwError("TypeError", "Cannot redefine property");
    // If a dense slot existed for this index (a default-attribute value being demoted to non-default
    // attributes), remove it so the index is not double-counted by the dense enumeration paths — the
    // map entry is now the single source of truth.
    if (in_dense) try arr.arrayDelete(i);
    // §10.4.2.1 step 3.h: [[Length]] still grows to include the index, but the dense store is NOT written
    // (that would double-count the index in enumeration). Reading `arr[i]` via the interpreter's
    // dense-only index path is an accepted M-subset gap for non-default-attribute indices.
    if (i + 1 > arr.array_length) arr.array_length = i + 1;
    return .{ .normal = .undefined };
}

/// §20.1.2.5 Object.defineProperties ( O, Properties ) — DefinePropertiesHelper over each own
/// enumerable key of `Properties`.
pub fn objectDefineProperties(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o != .object) return it.throwError("TypeError", "Object.defineProperties called on non-object");
    const props = if (args.len > 1) args[1] else .undefined;
    if (props != .object) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    var pit = props.object.properties.iterator();
    while (pit.next()) |entry| {
        if (!entry.value_ptr.enumerable) continue;
        const key = entry.key_ptr.*;
        const ac = try it.getProperty(props, key);
        if (ac.isAbrupt()) return ac;
        const r = try it.toPropertyDescriptor(ac.normal);
        switch (r) {
            .abrupt => |c| return c,
            .desc => |d| {
                // §20.1.2.5 step 5.b DefineOwnProperty — Array exotic: route `length` and integer
                // indices through the §10.4.2.1 path (ordinary string keys use the plain define).
                if (o.object.kind == .array and std.mem.eql(u8, key, "length")) {
                    const adc = try arrayDefineLength(it, o.object, d);
                    if (adc.isAbrupt()) return adc;
                } else if (o.object.kind == .array and arrayIndex(key) != null) {
                    const adc = try arrayDefineIndex(it, o.object, arrayIndex(key).?, key, d);
                    if (adc.isAbrupt()) return adc;
                } else {
                    const ok = try o.object.defineProperty(key, d);
                    if (!ok) return it.throwError("TypeError", "Cannot redefine property");
                }
            },
        }
    }
    // §20.1.2.5: OwnPropertyKeys includes SYMBOL keys — define each enumerable symbol-keyed one too.
    for (props.object.symbol_props.items) |sp| {
        if (!sp.pv.enumerable) continue;
        const ac = try it.getSymbolProperty(props, sp.key);
        if (ac.isAbrupt()) return ac;
        const r = try it.toPropertyDescriptor(ac.normal);
        switch (r) {
            .abrupt => |c| return c,
            .desc => |d| {
                const ok = try o.object.defineSymbolProperty(sp.key, d);
                if (!ok) return it.throwError("TypeError", "Cannot redefine property");
            },
        }
    }
    return .{ .normal = o };
}

/// §20.1.2.8 Object.getOwnPropertyDescriptor ( O, P ) → §6.2.6 FromPropertyDescriptor or undefined.
pub fn objectGetOwnPropertyDescriptor(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o != .object) {
        // §20.1.2.8 step 1: ToObject — a String boxes (index/length keys); else no own props.
        if (o == .string) return stringDescriptor(it, o.string, try it.toString(if (args.len > 1) args[1] else .undefined));
        if (o == .undefined or o == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
        return .{ .normal = .undefined };
    }
    // §20.1.2.8 step 2: ToPropertyKey(P) — a Symbol key reads the symbol-keyed store.
    const pk = try it.toPropertyKey(if (args.len > 1) args[1] else .undefined);
    if (pk.isAbrupt()) return pk.completion;
    if (o.object.proxy) |pd| { // §10.5.5 [[GetOwnProperty]] via the trap
        const kv: Value = if (pk.symbol) |sym| .{ .symbol = sym } else .{ .string = pk.key };
        return proxy.getOwnProperty(it, pd, kv);
    }
    if (pk.symbol) |sym| {
        for (o.object.symbol_props.items) |sp| {
            if (sp.key == sym) return fromPropertyValue(it, sp.pv);
        }
        return .{ .normal = .undefined };
    }
    const key = pk.key;
    // Array exotic: indices + `length` have synthetic descriptors (not in the property map).
    if (o.object.kind == .array) {
        if (std.mem.eql(u8, key, "length"))
            return fromDataDescriptor(it, .{ .number = @floatFromInt(o.object.arrayLen()) }, o.object.array_length_writable, false, false);
        if (arrayIndex(key)) |i| {
            // A non-default index define stored explicit attributes in the property map — those win.
            if (o.object.properties.get(key)) |pv| return fromPropertyValue(it, pv);
            if (o.object.arrayHas(i))
                // §10.4.2: an array index is writable/enumerable/configurable unless the array is
                // frozen (then its elements are non-writable + non-configurable).
                return fromDataDescriptor(it, o.object.arrayGet(i), !o.object.array_frozen, true, !o.object.array_frozen);
        }
    }
    const pv = o.object.properties.get(key) orelse return .{ .normal = .undefined };
    return fromPropertyValue(it, pv);
}

/// §6.2.6 FromPropertyDescriptor of a stored `PropertyValue` → a fresh descriptor object.
pub fn fromPropertyValue(it: *Interpreter, pv: object_mod.PropertyValue) EvalError!Completion {
    const desc = try Object.create(it.arena, it.globalProto("Object"));
    switch (pv.payload) {
        .data => |v| {
            try desc.set("value", v);
            try desc.set("writable", .{ .boolean = pv.writable });
        },
        .accessor => |a| {
            try desc.set("get", if (a.get) |g| .{ .object = g } else .undefined);
            try desc.set("set", if (a.set) |s| .{ .object = s } else .undefined);
        },
    }
    try desc.set("enumerable", .{ .boolean = pv.enumerable });
    try desc.set("configurable", .{ .boolean = pv.configurable });
    return .{ .normal = .{ .object = desc } };
}

pub fn fromDataDescriptor(it: *Interpreter, value: Value, writable: bool, enumerable: bool, configurable: bool) EvalError!Completion {
    return fromPropertyValue(it, .{
        .payload = .{ .data = value },
        .writable = writable,
        .enumerable = enumerable,
        .configurable = configurable,
    });
}

/// A String's own index/length property descriptor (the ToObject boxing path).
pub fn stringDescriptor(it: *Interpreter, s: []const u8, key: []const u8) EvalError!Completion {
    if (std.mem.eql(u8, key, "length"))
        return fromDataDescriptor(it, .{ .number = @floatFromInt(s.len) }, false, false, false);
    if (parseIndex(key)) |i| {
        if (i < s.len) return fromDataDescriptor(it, .{ .string = s[i .. i + 1] }, false, true, false);
    }
    return .{ .normal = .undefined };
}

/// §20.1.2.10 Object.getOwnPropertyNames ( O ) — all own string keys (enumerable or not). For an
/// Array: the indices (numeric order) + `"length"`, then ordinary string keys.
pub fn objectGetOwnPropertyNames(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    const arr = try Object.createArray(it.arena, it.arrayProto());
    switch (o) {
        .object => |obj| {
            if (obj.proxy != null) { // §10.5.11 → keep only string keys
                const keys = switch (try it.ordinaryOwnKeys(obj)) {
                    .keys => |k| k,
                    .abrupt => |c| return c,
                };
                for (keys) |k| if (k == .string) try arr.elements.append(it.arena, k);
                arr.array_length = arr.elements.items.len;
                return .{ .normal = .{ .object = arr } };
            }
            if (obj.kind == .array) {
                for (try obj.arrayIndices(it.arena)) |i| {
                    try arr.elements.append(it.arena, .{ .string = try numberToString(it.arena, @floatFromInt(i)) });
                }
                try arr.elements.append(it.arena, .{ .string = "length" });
            }
            var pit = obj.properties.iterator();
            while (pit.next()) |entry| try arr.elements.append(it.arena, .{ .string = entry.key_ptr.* });
        },
        .string => |s| {
            for (0..s.len) |i| try arr.elements.append(it.arena, .{ .string = try numberToString(it.arena, @floatFromInt(i)) });
            try arr.elements.append(it.arena, .{ .string = "length" });
        },
        .undefined, .null => return it.throwError("TypeError", "Cannot convert undefined or null to object"),
        else => {},
    }
    return .{ .normal = .{ .object = arr } };
}

/// §20.1.2.9 Object.getOwnPropertyDescriptors ( O ) — an object mapping each own key to its
/// FromPropertyDescriptor result (all own string keys, enumerable or not).
pub fn objectGetOwnPropertyDescriptors(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o == .undefined or o == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    const result = try Object.create(it.arena, it.objectProto());
    if (o == .object) {
        const obj = o.object;
        if (obj.kind == .array) {
            for (try obj.arrayIndices(it.arena)) |i| {
                const key = try numberToString(it.arena, @floatFromInt(i));
                const dc = try fromDataDescriptor(it, obj.arrayGet(i), true, true, true);
                try result.set(key, dc.normal);
            }
            const lc = try fromDataDescriptor(it, .{ .number = @floatFromInt(obj.arrayLen()) }, true, false, false);
            try result.set("length", lc.normal);
        }
        var pit = obj.properties.iterator();
        while (pit.next()) |entry| {
            const dc = try fromPropertyValue(it, entry.value_ptr.*);
            try result.set(entry.key_ptr.*, dc.normal);
        }
    }
    return .{ .normal = .{ .object = result } };
}

const KveKind = enum { keys, values, entries };

/// §20.1.2.19/.23/.6 Object.keys / values / entries — over the own ENUMERABLE string keys of
/// ToObject(O), in property order (Array indices first, then string keys; String chars for a
/// primitive string). `keys` → the key strings; `values` → the values (getters invoked); `entries`
/// → `[key, value]` two-element arrays.
pub fn objectKeysValuesEntries(it: *Interpreter, args: []const Value, kind: KveKind) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o == .undefined or o == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    const out = try Object.createArray(it.arena, it.arrayProto());
    var keys: std.ArrayListUnmanaged(Value) = .empty;
    if (try it.ownEnumerableKeys(o, &keys)) |abrupt| return abrupt;
    for (keys.items) |k| {
        switch (kind) {
            .keys => try out.elements.append(it.arena, k),
            .values, .entries => {
                const vc = try it.getProperty(o, k.string);
                if (vc.isAbrupt()) return vc;
                if (kind == .values) {
                    try out.elements.append(it.arena, vc.normal);
                } else {
                    const pair = try Object.createArray(it.arena, it.arrayProto());
                    try pair.elements.append(it.arena, k);
                    try pair.elements.append(it.arena, vc.normal);
                    try out.elements.append(it.arena, .{ .object = pair });
                }
            },
        }
    }
    return .{ .normal = .{ .object = out } };
}

/// §7.3.23 EnumerableOwnPropertyNames (key-collection half) — the OWN enumerable string keys of a
/// value (no prototype walk): Array indices (numeric order), ordinary own enumerable string keys,
/// or a primitive String's character indices. Used by Object.keys/values/entries and Object.assign.
/// Returns null on success, or the abrupt Completion (a Proxy trap throw/revoke) to propagate.
pub fn ownEnumerableKeys(it: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!?Completion {
    switch (value) {
        .object => |o| {
            if (o.proxy != null) {
                // §7.3.23: [[OwnPropertyKeys]] then keep only string keys whose [[GetOwnProperty]]
                // descriptor is present and [[Enumerable]].
                const keys = switch (try it.ordinaryOwnKeys(o)) {
                    .keys => |k| k,
                    .abrupt => |c| return c,
                };
                for (keys) |k| {
                    if (k != .string) continue;
                    switch (try it.ordinaryGetOwnProperty(o, k.string)) {
                        .pv => |pv| if (pv) |p| {
                            if (p.enumerable) try out.append(it.arena, k);
                        },
                        .abrupt => |c| return c,
                    }
                }
                return null;
            }
            if (o.kind == .array) {
                for (try o.arrayIndices(it.arena)) |i| {
                    try out.append(it.arena, .{ .string = try numberToString(it.arena, @floatFromInt(i)) });
                }
            }
            var pit = o.properties.iterator();
            while (pit.next()) |entry| {
                if (!entry.value_ptr.enumerable) continue; // §7.3.23: enumerable own keys only
                try out.append(it.arena, .{ .string = entry.key_ptr.* });
            }
        },
        .string => |s| {
            for (0..s.len) |i| try out.append(it.arena, .{ .string = try numberToString(it.arena, @floatFromInt(i)) });
        },
        else => {}, // number/boolean ToObject → no own enumerable string keys (M-subset)
    }
    return null;
}

/// §20.1.2.2 Object.create ( O, Properties ) — a new ordinary object with [[Prototype]] = O (an
/// object or null), then (if Properties is not undefined) §20.1.2.5 ObjectDefineProperties.
pub fn objectCreate(it: *Interpreter, args: []const Value) EvalError!Completion {
    const proto_arg = if (args.len > 0) args[0] else .undefined;
    const proto: ?*Object = switch (proto_arg) {
        .null => null,
        .object => |p| p,
        else => return it.throwError("TypeError", "Object prototype may only be an Object or null"),
    };
    const obj = try Object.create(it.arena, proto);
    const props = if (args.len > 1) args[1] else .undefined;
    if (props != .undefined) {
        const r = try objectDefineProperties(it, &.{ .{ .object = obj }, props });
        if (r.isAbrupt()) return r;
    }
    return .{ .normal = .{ .object = obj } };
}

/// §20.1.2.1 Object.assign ( target, ...sources ) — ToObject(target), then for each source copy
/// every own ENUMERABLE property (Get from source, Set on target). Returns target.
pub fn objectAssign(it: *Interpreter, args: []const Value) EvalError!Completion {
    const target = if (args.len > 0) args[0] else .undefined;
    if (target == .undefined or target == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    if (target != .object) return .{ .normal = target }; // M-subset: primitive target wrapper is read-only → return as-is
    if (args.len > 1) for (args[1..]) |source| {
        if (source == .undefined or source == .null) continue; // §20.1.2.1 step 4.a: skip nullish
        var keys: std.ArrayListUnmanaged(Value) = .empty;
        if (try it.ownEnumerableKeys(source, &keys)) |abrupt| return abrupt;
        for (keys.items) |k| {
            const vc = try it.getProperty(source, k.string);
            if (vc.isAbrupt()) return vc;
            const sc = try it.setProperty(target, k.string, vc.normal);
            if (sc.isAbrupt()) return sc;
        }
    };
    return .{ .normal = target };
}

/// §20.1.3.6 Object.prototype.toString ( ) — the brand/tag algorithm. Returns `"[object <Tag>]"`
/// where Tag is `Get(O, @@toStringTag)` (when a String) else the builtin tag from O's internal-slot
/// brand. undefined/null short-circuit to "Undefined"/"Null"; a primitive `this` boxes to its
/// wrapper brand (Number/String/Boolean) — symbol/bigint box to "Object".
pub fn objectToString(it: *Interpreter, this_val: Value) EvalError!Completion {
    // §20.1.3.6 steps 1-2.
    switch (this_val) {
        .undefined => return .{ .normal = .{ .string = "[object Undefined]" } },
        .null => return .{ .normal = .{ .string = "[object Null]" } },
        else => {},
    }
    // §20.1.3.6 steps 4-14: builtinTag from the ordered internal-slot probe.
    const builtin_tag: []const u8 = switch (this_val) {
        .object => |o| blk: {
            if (o.kind == .array) break :blk "Array"; // IsArray
            if (o.is_arguments) break :blk "Arguments"; // [[ParameterMap]]
            if (o.kind == .function) break :blk "Function"; // [[Call]]
            if (o.error_data) break :blk "Error"; // [[ErrorData]]
            if (o.kind == .date) break :blk "Date"; // §20.1.3.6 step 11: [[DateValue]]
            if (o.primitive) |p| switch (p) {
                .boolean => break :blk "Boolean", // [[BooleanData]]
                .number => break :blk "Number", // [[NumberData]]
                .string => break :blk "String", // [[StringData]]
                else => {},
            };
            break :blk "Object";
        },
        // A primitive receiver via `.call(prim)`: ToObject → the matching wrapper brand.
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        else => "Object", // symbol / bigint box to an ordinary Object
    };
    // §20.1.3.6 step 15: tag = Get(O, @@toStringTag); use it only when it is a String.
    var tag = builtin_tag;
    if (it.wellKnownSymbol("toStringTag")) |sym| {
        const tc = try it.getSymbolProperty(this_val, sym);
        if (tc.isAbrupt()) return tc;
        if (tc.normal == .string) tag = tc.normal.string;
    }
    // §20.1.3.6 step 16: "[object " + tag + "]".
    const out = try std.fmt.allocPrint(it.arena, "[object {s}]", .{tag});
    return .{ .normal = .{ .string = out } };
}

/// §20.1.2.7 Object.fromEntries ( iterable ) — a fresh ordinary object whose own enumerable data
/// properties come from the `[key, value]` entries of the iterable. Each entry must be an Object.
pub fn objectFromEntries(it: *Interpreter, args: []const Value) EvalError!Completion {
    const iterable = if (args.len > 0) args[0] else .undefined;
    // §20.1.2.7 step 1: RequireObjectCoercible (GetIterator throws on undefined/null anyway).
    if (iterable == .undefined or iterable == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    const obj = try Object.create(it.arena, it.objectProto());
    var entries: std.ArrayListUnmanaged(Value) = .empty;
    const lc = try it.iterateToList(iterable, &entries);
    if (lc.isAbrupt()) return lc;
    for (entries.items) |entry| {
        // §20.1.2.7 / §7.4 step: each entry must be an Object.
        if (entry != .object) return it.throwError("TypeError", "Iterator value is not an entry object");
        const kc = try it.getProperty(entry, "0");
        if (kc.isAbrupt()) return kc;
        const vc = try it.getProperty(entry, "1");
        if (vc.isAbrupt()) return vc;
        // §7.3.5 CreateDataPropertyOnObject: an own enumerable, writable, configurable data property.
        if (kc.normal == .symbol) {
            try obj.defineSymbolData(kc.normal.symbol, vc.normal, true, true, true);
        } else {
            const key = try it.toPropertyKeyString(kc.normal);
            try obj.defineData(key, vc.normal, true, true, true);
        }
    }
    return .{ .normal = .{ .object = obj } };
}

/// §20.1.2.13 Object.hasOwn ( O, P ) — HasOwnProperty(ToObject(O), ToPropertyKey(P)). Own string OR
/// symbol key, regardless of enumerability; no prototype walk.
pub fn objectHasOwn2(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o == .undefined or o == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    const p = if (args.len > 1) args[1] else .undefined;
    if (p == .symbol) {
        const has = if (o == .object) blk: {
            for (o.object.symbol_props.items) |sp| if (sp.key == p.symbol) break :blk true;
            break :blk false;
        } else false;
        return .{ .normal = .{ .boolean = has } };
    }
    const key = try it.toPropertyKeyString(p);
    return .{ .normal = .{ .boolean = try hasOwnProp(it, o, key) } };
}

/// §20.1.2.10 Object.getOwnPropertySymbols ( O ) — a fresh Array of the own Symbol keys of
/// ToObject(O), in insertion order. (Strings/primitives box to objects with no symbol keys.)
pub fn objectGetOwnPropertySymbols(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o == .undefined or o == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    const arr = try Object.createArray(it.arena, it.arrayProto());
    if (o == .object) {
        if (o.object.proxy != null) { // §10.5.11 → keep only symbol keys
            const keys = switch (try it.ordinaryOwnKeys(o.object)) {
                .keys => |k| k,
                .abrupt => |c| return c,
            };
            for (keys) |k| if (k == .symbol) try arr.elements.append(it.arena, k);
            arr.array_length = arr.elements.items.len;
            return .{ .normal = .{ .object = arr } };
        }
        for (o.object.symbol_props.items) |sp| {
            try arr.elements.append(it.arena, .{ .symbol = sp.key });
        }
    }
    return .{ .normal = .{ .object = arr } };
}

/// §20.1.2.11 Object.groupBy ( items, callback ) — §7.3.35 GroupBy (property coercion): iterate
/// `items`, key each by ToPropertyKey(callback(item, index)), collect items into per-key arrays,
/// and return an object with a NULL prototype whose own enumerable data properties are those arrays.
pub fn objectGroupBy(it: *Interpreter, args: []const Value) EvalError!Completion {
    const items = if (args.len > 0) args[0] else .undefined;
    const callback = if (args.len > 1) args[1] else .undefined;
    // §7.3.35 step 2: callback must be callable.
    if (callback != .object or callback.object.kind != .function) return it.throwError("TypeError", "Object.groupBy callback is not a function");
    if (items == .undefined or items == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
    var list: std.ArrayListUnmanaged(Value) = .empty;
    const lc = try it.iterateToList(items, &list);
    if (lc.isAbrupt()) return lc;
    // The result object has a null [[Prototype]] (§7.3.35 step 5: OrdinaryObjectCreate(null)).
    const obj = try Object.create(it.arena, null);
    for (list.items, 0..) |item, i| {
        const kc = try it.callFunction(callback.object, &.{ item, .{ .number = @floatFromInt(i) } }, .undefined);
        if (kc.isAbrupt()) return kc;
        // §7.3.35: a Symbol key is allowed (PROPERTY coercion → ToPropertyKey).
        if (kc.normal == .symbol) {
            const sym = kc.normal.symbol;
            const group: *Object = blk: {
                if (obj.getSymbolProp(sym)) |loc| if (loc.pv.payload == .data and loc.pv.payload.data == .object) break :blk loc.pv.payload.data.object;
                const fresh = try Object.createArray(it.arena, it.arrayProto());
                try obj.defineSymbolData(sym, .{ .object = fresh }, true, true, true);
                break :blk fresh;
            };
            try group.elements.append(it.arena, item);
        } else {
            const key = try it.toPropertyKeyString(kc.normal);
            const group: *Object = blk: {
                if (obj.properties.get(key)) |pv| if (pv.payload == .data and pv.payload.data == .object) break :blk pv.payload.data.object;
                const fresh = try Object.createArray(it.arena, it.arrayProto());
                try obj.defineData(key, .{ .object = fresh }, true, true, true);
                break :blk fresh;
            };
            try group.elements.append(it.arena, item);
        }
    }
    return .{ .normal = .{ .object = obj } };
}

/// §B.2.2.1.1 get Object.prototype.__proto__ — O = ToObject(this); return O.[[GetPrototypeOf]]().
/// Delegates to the §20.1.2.12 op (so a primitive `this` boxes to its wrapper proto's prototype).
pub fn objectProtoGet(it: *Interpreter, this_val: Value) EvalError!Completion {
    return objectGetPrototypeOf(it, &.{this_val});
}

/// §B.2.2.2–.5 the legacy accessor helpers on Object.prototype: `__defineGetter__`/`__defineSetter__`
/// install an enumerable, configurable accessor; `__lookupGetter__`/`__lookupSetter__` walk the
/// prototype chain for an own accessor with the requested get/set (a data property → undefined).
pub fn objectLegacyAccessor(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const o = switch (try it.toObjectForArrayLike(this_val)) { // §B.2.2.x step 1: ToObject(this)
        .obj => |obj| obj,
        .abrupt => |c| return c,
    };
    const key_arg: Value = if (args.len > 0) args[0] else .undefined;
    const is_get = eql(u8, name, "__defineGetter__") or eql(u8, name, "__lookupGetter__");

    if (eql(u8, name, "__defineGetter__") or eql(u8, name, "__defineSetter__")) {
        const fnv: Value = if (args.len > 1) args[1] else .undefined;
        if (fnv != .object or !isCallable(fnv.object)) {
            return it.throwError("TypeError", "Object.prototype.__define[GS]etter__: Expecting function");
        }
        const desc: object_mod.Descriptor = if (is_get)
            .{ .get = fnv.object, .enumerable = true, .configurable = true }
        else
            .{ .set = fnv.object, .enumerable = true, .configurable = true };
        const pk = try it.toPropertyKey(key_arg);
        if (pk.isAbrupt()) return pk.completion;
        const ok = if (pk.symbol) |sym| try o.defineSymbolProperty(sym, desc) else try o.defineProperty(pk.key, desc);
        if (!ok) return it.throwError("TypeError", "Cannot define accessor");
        return .{ .normal = .undefined };
    }

    // __lookupGetter__ / __lookupSetter__: walk the prototype chain for an own accessor.
    const pk = try it.toPropertyKey(key_arg);
    if (pk.isAbrupt()) return pk.completion;
    var cur: ?*Object = o;
    while (cur) |c| : (cur = c.prototype) {
        const pv: ?object_mod.PropertyValue = if (pk.symbol) |sym| blk: {
            for (c.symbol_props.items) |sp| {
                if (sp.key == sym) break :blk sp.pv;
            }
            break :blk null;
        } else (if (c.properties.get(pk.key)) |p| p else null);
        if (pv) |found| {
            switch (found.payload) {
                .accessor => |a| {
                    const fnp = if (is_get) a.get else a.set;
                    return .{ .normal = if (fnp) |f| .{ .object = f } else .undefined };
                },
                .data => return .{ .normal = .undefined }, // a data property shadows → no accessor
            }
        }
    }
    return .{ .normal = .undefined };
}

/// §B.2.2.1.2 set Object.prototype.__proto__ — O = RequireObjectCoercible(this). A value that is
/// neither Object nor null is a no-op (NOT a throw). A non-Object `this` is a no-op. Otherwise
/// O.[[SetPrototypeOf]](value) (may throw on a non-extensible/cyclic change). Returns undefined.
pub fn objectProtoSet(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val == .undefined or this_val == .null) return it.throwError("TypeError", "Cannot set property '__proto__' of null or undefined");
    const value = if (args.len > 0) args[0] else .undefined;
    // §B.2.2.1.2 steps 2-3: only Object/null values are applied; everything else is a silent no-op.
    if (value != .object and value != .null) return .{ .normal = .undefined };
    if (this_val != .object) return .{ .normal = .undefined }; // boxed primitive — no slot to set
    const sc = try objectSetPrototypeOf(it, &.{ this_val, value });
    if (sc.isAbrupt()) return sc;
    return .{ .normal = .undefined };
}

/// §20.1.2.12 Object.getPrototypeOf ( O ) — the [[Prototype]] of ToObject(O) (an object or null).
pub fn objectGetPrototypeOf(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    switch (o) {
        .object => |obj| return switch (try it.ordinaryGetPrototypeOf(obj)) { // §10.5.1 proxy-aware
            .proto => |p| .{ .normal = if (p) |pp| .{ .object = pp } else .null },
            .abrupt => |c| c,
        },
        .string => return .{ .normal = if (it.stringProto()) |p| .{ .object = p } else .null },
        .undefined, .null => return it.throwError("TypeError", "Cannot convert undefined or null to object"),
        else => return .{ .normal = .null }, // number/boolean: M-subset (no boxed wrapper proto)
    }
}

/// §20.1.2.22 Object.setPrototypeOf ( O, proto ) — set [[Prototype]] of O to proto (object or
/// null). A non-extensible object with a *different* current proto rejects (TypeError); a primitive
/// O is returned unchanged. Returns O.
pub fn objectSetPrototypeOf(it: *Interpreter, args: []const Value) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o == .undefined or o == .null) return it.throwError("TypeError", "Object.setPrototypeOf called on null or undefined");
    const proto_arg = if (args.len > 1) args[1] else .undefined;
    const new_proto: ?*Object = switch (proto_arg) {
        .null => null,
        .object => |p| p,
        else => return it.throwError("TypeError", "Object prototype may only be an Object or null"),
    };
    if (o != .object) return .{ .normal = o }; // primitive: no internal slot to set (M-subset)
    const obj = o.object;
    switch (try it.ordinarySetPrototypeOf(obj, new_proto)) { // §10.5.2 proxy-aware
        .ok => |ok| if (!ok) return it.throwError("TypeError", "#<Object> is not extensible"),
        .abrupt => |c| return c,
    }
    return .{ .normal = o };
}

const IntegrityOp = enum { freeze, seal, prevent };

/// §20.1.2.7/.21/.20 Object.freeze / seal / preventExtensions — apply the integrity level to O and
/// return O. A non-object argument is returned unchanged (§20.1.2.7 step 1).
pub fn objectSetIntegrity(it: *Interpreter, args: []const Value, op: IntegrityOp) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o != .object) return .{ .normal = o };
    if (o.object.proxy != null) {
        // §7.3.15 SetIntegrityLevel via the proxy's internal methods: PreventExtensions, then for
        // each own key DefineOwnProperty making it non-configurable (sealed) / also non-writable
        // for data props (frozen). §20.1.2.7/.21 throw on a failed PreventExtensions.
        const ok = switch (try it.ordinaryPreventExtensions(o.object)) {
            .ok => |x| x,
            .abrupt => |c| return c,
        };
        if (!ok) return it.throwError("TypeError", "Object.preventExtensions failed");
        if (op == .prevent) return .{ .normal = o };
        const keys = switch (try it.ordinaryOwnKeys(o.object)) {
            .keys => |k| k,
            .abrupt => |c| return c,
        };
        for (keys) |k| {
            const d: object_mod.Descriptor = if (op == .freeze) blk: {
                // Frozen: a data property also becomes non-writable. Read its current shape to know
                // whether it is an accessor (no [[Writable]]).
                const cur = try proxyOwnPV(it, o.object, k);
                if (cur.isAbrupt()) return cur.abrupt;
                const is_accessor = if (cur.pv) |pv| pv.payload == .accessor else false;
                break :blk if (is_accessor) .{ .configurable = false } else .{ .configurable = false, .writable = false };
            } else .{ .configurable = false };
            const dr = switch (k) {
                .symbol => |s| try it.ordinaryDefineOwnPropertySymbol(o.object, s, d),
                else => try it.ordinaryDefineOwnProperty(o.object, k.string, d),
            };
            switch (dr) {
                .ok => |dok| if (!dok) return it.throwError("TypeError", "Object.freeze/seal failed to redefine a property"),
                .abrupt => |c| return c,
            }
        }
        return .{ .normal = o };
    }
    switch (op) {
        .freeze => o.object.freezeObject(),
        .seal => o.object.sealObject(),
        .prevent => o.object.extensible = false,
    }
    return .{ .normal = o };
}

const ProxyPV = union(enum) {
    pv: ?object_mod.PropertyValue,
    abrupt: Completion,
    fn isAbrupt(s: ProxyPV) bool {
        return s == .abrupt;
    }
};

fn proxyOwnPV(it: *Interpreter, o: *Object, key: Value) EvalError!ProxyPV {
    switch (key) {
        .symbol => |s| return switch (try it.ordinaryGetOwnPropertySymbol(o, s)) {
            .pv => |pv| .{ .pv = pv },
            .abrupt => |c| .{ .abrupt = c },
        },
        else => return switch (try it.ordinaryGetOwnProperty(o, key.string)) {
            .pv => |pv| .{ .pv = pv },
            .abrupt => |c| .{ .abrupt = c },
        },
    }
}

const IntegrityTest = enum { frozen, sealed, extensible };

/// §20.1.2.16/.17/.15 Object.isFrozen / isSealed / isExtensible. A non-object argument is treated
/// as already frozen/sealed (true) and not extensible (false) per the spec's primitive handling.
pub fn objectTestIntegrity(it: *Interpreter, args: []const Value, t: IntegrityTest) EvalError!Completion {
    const o = if (args.len > 0) args[0] else .undefined;
    if (o != .object) {
        // §20.1.2.15 step 2 / §20.1.2.16-17: a primitive is non-extensible and (vacuously) frozen+sealed.
        return .{ .normal = .{ .boolean = t != .extensible } };
    }
    if (o.object.proxy != null) {
        const ext = switch (try it.ordinaryIsExtensible(o.object)) { // §10.5.3
            .ext => |x| x,
            .abrupt => |c| return c,
        };
        if (t == .extensible) return .{ .normal = .{ .boolean = ext } };
        // §7.3.16 TestIntegrityLevel: an extensible target is neither frozen nor sealed; otherwise
        // every own property must be non-configurable (frozen additionally: every data prop non-writable).
        if (ext) return .{ .normal = .{ .boolean = false } };
        const keys = switch (try it.ordinaryOwnKeys(o.object)) {
            .keys => |k| k,
            .abrupt => |c| return c,
        };
        for (keys) |k| {
            const cur = try proxyOwnPV(it, o.object, k);
            if (cur.isAbrupt()) return cur.abrupt;
            if (cur.pv) |pv| {
                if (pv.configurable) return .{ .normal = .{ .boolean = false } };
                if (t == .frozen and pv.payload == .data and pv.writable) return .{ .normal = .{ .boolean = false } };
            }
        }
        return .{ .normal = .{ .boolean = true } };
    }
    const r = switch (t) {
        .frozen => o.object.isFrozenObject(),
        .sealed => o.object.isSealedObject(),
        .extensible => o.object.extensible,
    };
    return .{ .normal = .{ .boolean = r } };
}

/// §20.1.3.2 Object.prototype.hasOwnProperty ( V ) — own property only (no chain walk). §20.1.3.2:
/// ToPropertyKey(V) BEFORE ToObject(this), so a Symbol key checks the symbol-keyed own store.
pub fn objectHasOwnProperty(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const pk = try it.toPropertyKey(if (args.len > 0) args[0] else .undefined);
    if (pk.isAbrupt()) return pk.completion;
    if (pk.symbol) |sym| {
        if (this_val == .undefined or this_val == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
        if (this_val == .object) {
            for (this_val.object.symbol_props.items) |sp| if (sp.key == sym) return .{ .normal = .{ .boolean = true } };
        }
        return .{ .normal = .{ .boolean = false } };
    }
    return .{ .normal = .{ .boolean = try hasOwnProp(it, this_val, pk.key) } };
}

/// HasOwnProperty over the engine's value model (Array indices/length, String index/length,
/// ordinary own property map). Used by hasOwnProperty + propertyIsEnumerable.
pub fn hasOwnProp(it: *Interpreter, base: Value, key: []const u8) EvalError!bool {
    switch (base) {
        .object => |o| {
            if (o.kind == .array) {
                if (std.mem.eql(u8, key, "length")) return true;
                if (parseIndex(key)) |i| if (o.arrayHas(i)) return true;
            }
            return o.properties.contains(key);
        },
        .string => |s| {
            if (std.mem.eql(u8, key, "length")) return true;
            if (parseIndex(key)) |i| return i < s.len;
            return false;
        },
        .undefined, .null => {
            _ = try it.throwError("TypeError", "Cannot convert undefined or null to object");
            return false;
        },
        else => return false,
    }
}

/// §20.1.3.4 Object.prototype.propertyIsEnumerable ( V ). ToPropertyKey(V) first — a Symbol key reads
/// the symbol-keyed own store's [[Enumerable]] attribute.
pub fn objectPropertyIsEnumerable(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    const pk = try it.toPropertyKey(if (args.len > 0) args[0] else .undefined);
    if (pk.isAbrupt()) return pk.completion;
    if (pk.symbol) |sym| {
        if (this_val == .undefined or this_val == .null) return it.throwError("TypeError", "Cannot convert undefined or null to object");
        if (this_val == .object) {
            for (this_val.object.symbol_props.items) |sp| if (sp.key == sym) return .{ .normal = .{ .boolean = sp.pv.enumerable } };
        }
        return .{ .normal = .{ .boolean = false } };
    }
    const key = pk.key;
    const enumerable: bool = switch (this_val) {
        .object => |o| blk: {
            if (o.kind == .array) {
                if (std.mem.eql(u8, key, "length")) break :blk false; // Array length is non-enumerable
                if (parseIndex(key)) |i| if (o.arrayHas(i)) break :blk true;
            }
            break :blk o.isEnumerable(key);
        },
        .string => |s| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk false;
            if (parseIndex(key)) |i| break :blk i < s.len; // String chars are enumerable
            break :blk false;
        },
        .undefined, .null => return it.throwError("TypeError", "Cannot convert undefined or null to object"),
        else => false,
    };
    return .{ .normal = .{ .boolean = enumerable } };
}

/// §20.1.3.3 Object.prototype.isPrototypeOf ( V ) — is `this` anywhere on V's prototype chain.
pub fn objectIsPrototypeOf(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    _ = it;
    if (this_val != .object) return .{ .normal = .{ .boolean = false } };
    const target = this_val.object;
    const v = if (args.len > 0) args[0] else .undefined;
    if (v != .object) return .{ .normal = .{ .boolean = false } };
    var p: ?*Object = v.object.prototype;
    while (p) |proto| {
        if (proto == target) return .{ .normal = .{ .boolean = true } };
        p = proto.prototype;
    }
    return .{ .normal = .{ .boolean = false } };
}
