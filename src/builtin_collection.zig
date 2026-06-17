//! §24.1 `Map.prototype` + §24.2 `Set.prototype` methods (and, later, §24.3/§24.4 WeakMap/WeakSet).
//! Native built-ins dispatched from the interpreter's `callNative` (`map_method` / `set_method`);
//! `this` is the receiver collection. The backing store (`object.zig` `Collection`) keeps entries in
//! insertion order with SameValueZero keying and tombstone deletes (so live iterators stay correct).
//! Lives in its own file so the interpreter stays the evaluator (mirrors `builtin_array.zig`).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const object_mod = @import("object.zig");
const Collection = object_mod.Collection;
const CollectionKind = object_mod.CollectionKind;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

/// §24.1.3.9 / §24.2.3.1: a stored key normalizes `-0` to `+0` (so `m.set(-0,…)` then `m.get(0)` hits).
/// Every other value is stored as-is. SameValueZero already treats `-0`/`+0` equal for LOOKUP; this
/// makes the OBSERVABLE key (yielded by iteration / passed to forEach) the normalized `+0`.
fn normKey(v: Value) Value {
    if (v == .number and v.number == 0) return .{ .number = 0 }; // collapses -0 → +0
    return v;
}

/// Linear scan for a PRESENT entry whose key is SameValueZero-equal to `key`. Returns its index.
fn findIndex(coll: *Collection, key: Value) ?usize {
    for (coll.entries.items, 0..) |e, i| {
        if (e.present and ops.sameValueZero(e.key, key)) return i;
    }
    return null;
}

/// Insert or update (Map.set / Set.add / WeakMap.set / WeakSet.add backing): SameValueZero-keyed.
pub fn put(it: *Interpreter, coll: *Collection, key: Value, value: Value) EvalError!void {
    const k = normKey(key);
    if (findIndex(coll, k)) |i| {
        coll.entries.items[i].value = value;
        return;
    }
    try coll.entries.append(it.arena, .{ .key = k, .value = value });
    coll.size += 1;
}

/// §24.1.3.3 delete: tombstone the entry (keep the record so existing iterators stay valid).
fn remove(coll: *Collection, key: Value) bool {
    if (findIndex(coll, key)) |i| {
        coll.entries.items[i].present = false;
        coll.entries.items[i].key = .undefined; // release references held by the dead slot
        coll.entries.items[i].value = .undefined;
        coll.size -= 1;
        return true;
    }
    return false;
}

/// §24.1.3.1 clear: tombstone every entry (records stay so an in-flight iterator just sees `done`).
fn clear(coll: *Collection) void {
    for (coll.entries.items) |*e| {
        e.present = false;
        e.key = .undefined;
        e.value = .undefined;
    }
    coll.size = 0;
}

/// Brand check: `this` must be an object carrying a `Collection` of exactly `kind` (a Map method on a
/// Set, or on a plain object, is a TypeError — §24.1.3 "If M does not have a [[MapData]] internal slot").
fn requireColl(it: *Interpreter, this_val: Value, kind: CollectionKind) EvalError!union(enum) { coll: *Collection, abrupt: Completion } {
    if (this_val == .object) {
        if (this_val.object.collection) |c| {
            if (c.kind == kind) return .{ .coll = c };
        }
    }
    return .{ .abrupt = try it.throwError("TypeError", "method called on an incompatible receiver") };
}

/// §24.1.3.5 / §24.2.3.6 forEach ( callbackfn [, thisArg] ) — visit live entries in insertion order,
/// calling `callbackfn(value, key, collection)`. Entries added during the walk ARE visited; entries
/// deleted before being reached are skipped (the tombstone check each step). For a Set, key === value.
fn forEach(it: *Interpreter, coll: *Collection, this_val: Value, args: []const Value) EvalError!Completion {
    const cb: Value = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or !interp.isCallable(cb.object)) {
        return it.throwError("TypeError", "callback is not a function");
    }
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    var i: usize = 0;
    // Re-read `entries.items` and `.len` each step: the callback may `set`/`add` (growing, possibly
    // reallocating the list) or `delete` (tombstoning a not-yet-visited slot).
    while (i < coll.entries.items.len) : (i += 1) {
        if (!coll.entries.items[i].present) continue;
        const value = coll.entries.items[i].value;
        const key = coll.entries.items[i].key;
        const r = try it.callFunction(cb.object, &.{ value, key, this_val }, this_arg);
        if (r.isAbrupt()) return r;
    }
    return .{ .normal = .undefined };
}

/// §24.1.3 Map.prototype dispatch (get/set/has/delete/clear/forEach). keys/values/entries/size are
/// separate natives (collection_iterator / collection_size) handled in the interpreter.
pub fn mapMethod(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const coll = switch (try requireColl(it, this_val, .map)) {
        .coll => |c| c,
        .abrupt => |c| return c,
    };
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    const a1: Value = if (args.len > 1) args[1] else .undefined;
    if (eql(u8, name, "get")) {
        if (findIndex(coll, a0)) |i| return .{ .normal = coll.entries.items[i].value };
        return .{ .normal = .undefined };
    }
    if (eql(u8, name, "set")) {
        try put(it, coll, a0, a1);
        return .{ .normal = this_val }; // §24.1.3.9 returns the Map
    }
    if (eql(u8, name, "has")) return .{ .normal = .{ .boolean = findIndex(coll, a0) != null } };
    if (eql(u8, name, "delete")) return .{ .normal = .{ .boolean = remove(coll, a0) } };
    if (eql(u8, name, "clear")) {
        clear(coll);
        return .{ .normal = .undefined };
    }
    if (eql(u8, name, "forEach")) return forEach(it, coll, this_val, args);
    unreachable;
}

/// §7.3.x CanBeHeldWeakly ( v ) — a WeakMap/WeakSet key must be an Object or a Symbol that is not in
/// the GlobalSymbolRegistry. The engine has no `Symbol.for` registry, so every Symbol qualifies.
fn canBeHeldWeakly(v: Value) bool {
    return v == .object or v == .symbol;
}

/// §24.3.3 WeakMap.prototype dispatch (get/set/has/delete). No iteration / size / clear / forEach: a
/// WeakMap is not enumerable. A non-weak-holdable key throws on `set` but is a silent miss elsewhere.
pub fn weakMapMethod(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const coll = switch (try requireColl(it, this_val, .weakmap)) {
        .coll => |c| c,
        .abrupt => |c| return c,
    };
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    const a1: Value = if (args.len > 1) args[1] else .undefined;
    if (eql(u8, name, "set")) {
        if (!canBeHeldWeakly(a0)) return it.throwError("TypeError", "Invalid value used as weak map key");
        try put(it, coll, a0, a1);
        return .{ .normal = this_val }; // §24.3.3.5 returns the WeakMap
    }
    if (eql(u8, name, "get")) {
        if (canBeHeldWeakly(a0)) if (findIndex(coll, a0)) |i| return .{ .normal = coll.entries.items[i].value };
        return .{ .normal = .undefined };
    }
    if (eql(u8, name, "has")) return .{ .normal = .{ .boolean = canBeHeldWeakly(a0) and findIndex(coll, a0) != null } };
    if (eql(u8, name, "delete")) return .{ .normal = .{ .boolean = canBeHeldWeakly(a0) and remove(coll, a0) } };
    unreachable;
}

/// §24.4.3 WeakSet.prototype dispatch (add/has/delete).
pub fn weakSetMethod(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const coll = switch (try requireColl(it, this_val, .weakset)) {
        .coll => |c| c,
        .abrupt => |c| return c,
    };
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    if (eql(u8, name, "add")) {
        if (!canBeHeldWeakly(a0)) return it.throwError("TypeError", "Invalid value used in weak set");
        if (findIndex(coll, a0) == null) {
            try coll.entries.append(it.arena, .{ .key = a0, .value = a0 });
            coll.size += 1;
        }
        return .{ .normal = this_val }; // §24.4.3.1 returns the WeakSet
    }
    if (eql(u8, name, "has")) return .{ .normal = .{ .boolean = canBeHeldWeakly(a0) and findIndex(coll, a0) != null } };
    if (eql(u8, name, "delete")) return .{ .normal = .{ .boolean = canBeHeldWeakly(a0) and remove(coll, a0) } };
    unreachable;
}

/// §24.2.3 Set.prototype dispatch (add/has/delete/clear/forEach). For a Set the stored value mirrors
/// the key, so forEach / iteration yield the element for both the value and key positions.
pub fn setMethod(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    const coll = switch (try requireColl(it, this_val, .set)) {
        .coll => |c| c,
        .abrupt => |c| return c,
    };
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    if (eql(u8, name, "add")) {
        const k = normKey(a0);
        if (findIndex(coll, k) == null) {
            try coll.entries.append(it.arena, .{ .key = k, .value = k }); // §24.2.3.1: value === key
            coll.size += 1;
        }
        return .{ .normal = this_val }; // §24.2.3.1 returns the Set
    }
    if (eql(u8, name, "has")) return .{ .normal = .{ .boolean = findIndex(coll, a0) != null } };
    if (eql(u8, name, "delete")) return .{ .normal = .{ .boolean = remove(coll, a0) } };
    if (eql(u8, name, "clear")) {
        clear(coll);
        return .{ .normal = .undefined };
    }
    if (eql(u8, name, "forEach")) return forEach(it, coll, this_val, args);
    unreachable;
}
