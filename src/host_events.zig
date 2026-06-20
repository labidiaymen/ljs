//! HOST runtime (Node axis, spec 103 — NOT ECMA-262): Node's `events` core module, i.e. the
//! `EventEmitter` class. Requireable as `require('events')` (the module exports IS the class, with
//! `module.exports.EventEmitter === EventEmitter` too). Host-only — never on the Test262 path.
//!
//! Per-instance state: each emitter stores its listener registry as a hidden own property
//! `"%events%"` on the instance — a plain Object mapping event-name (a string key) → an Array of
//! "holder" objects. Each holder is a plain object carrying hidden own props `"%fn%"` (the listener
//! function) and `"%once%"` (a boolean). Holders let `once`/`listeners`/`rawListeners`/`emit`
//! cooperate without needing to synthesize wrapper functions. The store is created lazily on first
//! mutation (so calling an emitter without `new`, or a subclass `super()` path, still works).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

const STORE_KEY = "%events%";
const FN_KEY = "%fn%";
const ONCE_KEY = "%once%";
const MAX_KEY = "%maxListeners%";

// ── build the module ───────────────────────────────────────────────────────────

/// Build the `events` core-module exports object: the `EventEmitter` constructor (a `.events_method`
/// native named "EventEmitter") carrying its `prototype` with all the instance methods, plus
/// `EventEmitter.EventEmitter === EventEmitter`. Returned object IS the class (so
/// `require('events')` and `require('events').EventEmitter` both work).
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;

    // EventEmitter.prototype — holds the instance methods; [[Prototype]] = %Object.prototype%.
    const proto = try Object.create(arena, self.objectProto());

    // The EventEmitter constructor.
    const ctor = try Object.createNative(arena, .events_method, "EventEmitter");
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = "EventEmitter" }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    // Prototype (instance) methods.
    const proto_methods = [_][]const u8{
        "on",                  "addListener",        "once",            "off",
        "removeListener",      "removeAllListeners", "emit",            "listeners",
        "rawListeners",        "listenerCount",      "eventNames",      "prependListener",
        "prependOnceListener", "setMaxListeners",    "getMaxListeners",
    };
    for (proto_methods) |name| try defineMethod(self, proto, name);

    // `events.EventEmitter === events` (the module exports IS the class, and also references itself).
    try ctor.defineData("EventEmitter", .{ .object = ctor }, true, false, true);
    // Node's default `EventEmitter.defaultMaxListeners` (informational; no warning is emitted).
    try ctor.defineData("defaultMaxListeners", .{ .number = 10 }, true, false, true);

    return ctor;
}

fn defineMethod(self: *Interpreter, target: *Object, name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .events_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

// ── dispatch ───────────────────────────────────────────────────────────────────

/// Dispatch a `.events_method` native by `func.native_name`. The constructor ("EventEmitter") is
/// reached both as a `[[Call]]` and a `[[Construct]]`; the instance methods use `this_val` as the
/// receiver emitter.
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;

    // The constructor: `new EventEmitter()` (or `super()` from a subclass) — initialize the store on
    // the new instance (`this_val`). A plain `EventEmitter()` call without `new` simply returns the
    // (uninitialized) receiver; the store is created lazily on first use anyway.
    if (eq(u8, name, "EventEmitter")) {
        if (self.native_new_target != .undefined and this_val == .object) {
            _ = try ensureStore(self, this_val.object);
            return .{ .normal = this_val };
        }
        return .{ .normal = .undefined };
    }

    // Instance methods — receiver must be an object.
    if (this_val != .object) return self.throwError("TypeError", "EventEmitter method called on non-object");
    const emitter = this_val.object;

    if (eq(u8, name, "on") or eq(u8, name, "addListener")) return addImpl(self, emitter, this_val, args, false, false);
    if (eq(u8, name, "prependListener")) return addImpl(self, emitter, this_val, args, true, false);
    if (eq(u8, name, "once")) return addImpl(self, emitter, this_val, args, false, true);
    if (eq(u8, name, "prependOnceListener")) return addImpl(self, emitter, this_val, args, true, true);
    if (eq(u8, name, "off") or eq(u8, name, "removeListener")) return removeListener(self, emitter, this_val, args);
    if (eq(u8, name, "removeAllListeners")) return removeAllListeners(self, emitter, this_val, args);
    if (eq(u8, name, "emit")) return emit(self, emitter, this_val, args);
    if (eq(u8, name, "listeners")) return listeners(self, emitter, args, false);
    if (eq(u8, name, "rawListeners")) return listeners(self, emitter, args, true);
    if (eq(u8, name, "listenerCount")) return listenerCount(self, emitter, args);
    if (eq(u8, name, "eventNames")) return eventNames(self, emitter);
    if (eq(u8, name, "setMaxListeners")) return setMaxListeners(self, emitter, this_val, args);
    if (eq(u8, name, "getMaxListeners")) return getMaxListeners(emitter);

    return .{ .normal = .undefined };
}

// ── store helpers ──────────────────────────────────────────────────────────────

/// Get (creating if absent) the per-instance listener-store object held on `emitter`'s hidden
/// `"%events%"` own prop. The store maps event-name string → Array of holder objects.
fn ensureStore(self: *Interpreter, emitter: *Object) EvalError!*Object {
    if (emitter.get(STORE_KEY)) |v| if (v == .object) return v.object;
    const store = Object.create(self.arena, null) catch return error.OutOfMemory;
    try emitter.defineData(STORE_KEY, .{ .object = store }, true, false, false);
    return store;
}

/// The store if it exists, else null (no allocation).
fn storeOf(emitter: *Object) ?*Object {
    if (emitter.get(STORE_KEY)) |v| if (v == .object) return v.object;
    return null;
}

/// Coerce an event-name argument to its string key.
fn eventKey(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toStringValuePub(v);
}

/// The listener-array for `key` in `store`, or null. Stored under the (engine-managed) string key.
fn arrayFor(store: *Object, key: []const u8) ?*Object {
    if (store.get(key)) |v| if (v == .object) return v.object;
    return null;
}

/// Make a holder object wrapping `listener` with the `once` flag.
fn makeHolder(self: *Interpreter, listener: *Object, once: bool) EvalError!*Object {
    const h = Object.create(self.arena, null) catch return error.OutOfMemory;
    try h.defineData(FN_KEY, .{ .object = listener }, true, false, false);
    try h.defineData(ONCE_KEY, .{ .boolean = once }, true, false, false);
    return h;
}

// ── add / remove ───────────────────────────────────────────────────────────────

fn addImpl(self: *Interpreter, emitter: *Object, this_val: Value, args: []const Value, prepend: bool, once: bool) EvalError!Completion {
    const key_c = try eventKey(self, if (args.len > 0) args[0] else .undefined);
    if (key_c.isAbrupt()) return key_c;
    const listener_v: Value = if (args.len > 1) args[1] else .undefined;
    if (listener_v != .object or listener_v.object.kind != .function)
        return self.throwError("TypeError", "The \"listener\" argument must be of type function");

    const store = try ensureStore(self, emitter);
    // Copy the key into arena-owned memory (the toString result may alias a transient buffer).
    const key = self.arena.dupe(u8, key_c.normal.string) catch return error.OutOfMemory;

    const arr = if (arrayFor(store, key)) |a| a else blk: {
        const a = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
        try store.defineData(key, .{ .object = a }, true, false, false);
        break :blk a;
    };
    const holder = try makeHolder(self, listener_v.object, once);

    if (prepend) {
        // Insert at the front: shift everything up by one.
        const n = arr.array_length;
        var i: usize = n;
        while (i > 0) : (i -= 1) {
            const prev = arr.arrayGet(i - 1);
            try arr.arraySet(self.arena, i, prev);
        }
        try arr.arraySet(self.arena, 0, .{ .object = holder });
    } else {
        try arr.arraySet(self.arena, arr.array_length, .{ .object = holder });
    }
    return .{ .normal = this_val };
}

fn removeListener(self: *Interpreter, emitter: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const key_c = try eventKey(self, if (args.len > 0) args[0] else .undefined);
    if (key_c.isAbrupt()) return key_c;
    const listener_v: Value = if (args.len > 1) args[1] else .undefined;
    const store = storeOf(emitter) orelse return .{ .normal = this_val };
    const arr = arrayFor(store, key_c.normal.string) orelse return .{ .normal = this_val };

    // Remove the LAST matching holder (Node removes at most one, the most recently-added match).
    const n = arr.array_length;
    var idx: ?usize = null;
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        const h = arr.arrayGet(i - 1);
        if (h == .object) if (h.object.get(FN_KEY)) |fv| {
            if (fv == .object and listener_v == .object and fv.object == listener_v.object) {
                idx = i - 1;
                break;
            }
        };
    }
    if (idx) |found| {
        var j: usize = found;
        while (j + 1 < n) : (j += 1) {
            const nxt = arr.arrayGet(j + 1);
            try arr.arraySet(self.arena, j, nxt);
        }
        try arr.arraySetLen(n - 1);
    }
    return .{ .normal = this_val };
}

fn removeAllListeners(self: *Interpreter, emitter: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const store = storeOf(emitter) orelse return .{ .normal = this_val };
    if (args.len > 0 and args[0] != .undefined) {
        const key_c = try eventKey(self, args[0]);
        if (key_c.isAbrupt()) return key_c;
        if (arrayFor(store, key_c.normal.string)) |arr| try arr.arraySetLen(0);
    } else {
        // Clear every event: empty each listener array.
        var it = store.properties.iterator();
        while (it.next()) |entry| {
            const pv = entry.value_ptr.*;
            if (pv.payload == .data and pv.payload.data == .object) {
                const arr = pv.payload.data.object;
                if (arr.kind == .array) try arr.arraySetLen(0);
            }
        }
    }
    return .{ .normal = this_val };
}

// ── emit ───────────────────────────────────────────────────────────────────────

fn emit(self: *Interpreter, emitter: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const key_c = try eventKey(self, if (args.len > 0) args[0] else .undefined);
    if (key_c.isAbrupt()) return key_c;
    const key = key_c.normal.string;
    const is_error = std.mem.eql(u8, key, "error");

    const store = storeOf(emitter);
    const arr = if (store) |s| arrayFor(s, key) else null;
    const have = arr != null and arr.?.array_length > 0;

    if (!have) {
        // §EventEmitter `emit('error', err)` with no listener → throw the error value itself.
        if (is_error) {
            const err_v: Value = if (args.len > 1) args[1] else .undefined;
            return .{ .throw = err_v };
        }
        return .{ .normal = .{ .boolean = false } };
    }

    // The forwarded args are everything after the event name.
    const fwd: []const Value = if (args.len > 1) args[1..] else &[_]Value{};

    // Snapshot the current holders (a listener may mutate the array; emit uses the snapshot).
    const a = arr.?;
    const n = a.array_length;
    var holders = std.ArrayListUnmanaged(*Object).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = a.arrayGet(i);
        if (h == .object) holders.append(self.arena, h.object) catch return error.OutOfMemory;
    }

    // First remove any `once` holders from the live array (so re-entrant emits don't refire them).
    for (holders.items) |h| {
        if (h.get(ONCE_KEY)) |ov| if (ov == .boolean and ov.boolean) {
            try removeHolder(self, a, h);
        };
    }

    // Then invoke each captured listener synchronously, in add order, with `this` = emitter.
    for (holders.items) |h| {
        const fv = h.get(FN_KEY) orelse continue;
        if (fv != .object) continue;
        const rc = try self.callFunction(fv.object, fwd, this_val);
        if (rc.isAbrupt()) return rc;
    }
    return .{ .normal = .{ .boolean = true } };
}

/// Remove a specific holder object (by identity) from a live listener array.
fn removeHolder(self: *Interpreter, arr: *Object, holder: *Object) EvalError!void {
    const n = arr.array_length;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = arr.arrayGet(i);
        if (h == .object and h.object == holder) {
            var j: usize = i;
            while (j + 1 < n) : (j += 1) {
                const nxt = arr.arrayGet(j + 1);
                try arr.arraySet(self.arena, j, nxt);
            }
            try arr.arraySetLen(n - 1);
            return;
        }
    }
}

// ── queries ────────────────────────────────────────────────────────────────────

/// `listeners(type)` / `rawListeners(type)` — an Array of the listener functions for `type`. (We do
/// not synthesize once-wrappers, so `raw` and non-`raw` return the same underlying functions.)
fn listeners(self: *Interpreter, emitter: *Object, args: []const Value, raw: bool) EvalError!Completion {
    _ = raw;
    const out = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
    const key_c = try eventKey(self, if (args.len > 0) args[0] else .undefined);
    if (key_c.isAbrupt()) return key_c;
    const store = storeOf(emitter) orelse return .{ .normal = .{ .object = out } };
    const arr = arrayFor(store, key_c.normal.string) orelse return .{ .normal = .{ .object = out } };
    const n = arr.array_length;
    var i: usize = 0;
    var o: usize = 0;
    while (i < n) : (i += 1) {
        const h = arr.arrayGet(i);
        if (h == .object) if (h.object.get(FN_KEY)) |fv| {
            try out.arraySet(self.arena, o, fv);
            o += 1;
        };
    }
    return .{ .normal = .{ .object = out } };
}

fn listenerCount(self: *Interpreter, emitter: *Object, args: []const Value) EvalError!Completion {
    const key_c = try eventKey(self, if (args.len > 0) args[0] else .undefined);
    if (key_c.isAbrupt()) return key_c;
    const store = storeOf(emitter) orelse return .{ .normal = .{ .number = 0 } };
    const arr = arrayFor(store, key_c.normal.string) orelse return .{ .normal = .{ .number = 0 } };
    return .{ .normal = .{ .number = @floatFromInt(arr.array_length) } };
}

/// `eventNames()` — an Array of the event names that currently have at least one listener.
fn eventNames(self: *Interpreter, emitter: *Object) EvalError!Completion {
    const out = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
    const store = storeOf(emitter) orelse return .{ .normal = .{ .object = out } };
    var it = store.properties.iterator();
    var o: usize = 0;
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (pv.payload == .data and pv.payload.data == .object) {
            const arr = pv.payload.data.object;
            if (arr.kind == .array and arr.array_length > 0) {
                const name = self.arena.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                try out.arraySet(self.arena, o, .{ .string = name });
                o += 1;
            }
        }
    }
    return .{ .normal = .{ .object = out } };
}

fn setMaxListeners(self: *Interpreter, emitter: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const nd = try self.toNumberV(if (args.len > 0) args[0] else .undefined);
    if (nd.isAbrupt()) return nd;
    try emitter.defineData(MAX_KEY, .{ .number = nd.normal.number }, true, false, false);
    return .{ .normal = this_val };
}

fn getMaxListeners(emitter: *Object) EvalError!Completion {
    if (emitter.get(MAX_KEY)) |v| if (v == .number) return .{ .normal = v };
    return .{ .normal = .{ .number = 10 } }; // EventEmitter.defaultMaxListeners
}
