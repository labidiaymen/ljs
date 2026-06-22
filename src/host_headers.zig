//! HOST runtime (Node axis — NOT ECMA-262): the WHATWG `Headers` GLOBAL class (fetch spec §2.2).
//! Installed host-only as a GLOBAL constructor (via `host_setup.installHostGlobals`), like Node and
//! browsers expose it. NEVER on the Test262 engine surface, so 0 Test262 regressions by construction.
//!
//! Mechanics (mirrors `host_url.zig`'s URLSearchParams — a case-insensitive multi-map):
//!   • The constructor and every prototype method are `.headers_method` natives whose `native_name`
//!     selects the operation; a hidden own `"%kind%"` on the function distinguishes the constructor
//!     family ("hdr_ctor") from the prototype-method family ("hdr").
//!   • A `new Headers([init])` receives the freshly-created instance as `this_val` (see
//!     `interp_expr.constructNT`, which lists `.headers_method` with name "Headers" as constructible).
//!   • Per-instance storage is a hidden own `"%hdr%"` JS Array of 2-element `[lowercased-name, value]`
//!     arrays (header names are case-INSENSITIVE — stored lowercased). get/set/append/delete mutate
//!     that array; the iterators build a fresh sorted-by-name array and reuse the engine's array
//!     iterator (`interp_collection.makeArrayIterator`). Multiple values for one name are combined
//!     with ", " on `get` (and `forEach`/iterators), per the fetch spec's "combine" step.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

// ════════════════════════════════════════════════════════════════════════════
//  install (global) + constructor / prototype builders
// ════════════════════════════════════════════════════════════════════════════

/// Build + declare the `Headers` global constructor on `self.globals`, and mirror it onto the reified
/// global object. Called from `host_setup.installHostGlobals`.
pub fn install(self: *Interpreter) EvalError!void {
    const env = self.globals orelse return;
    const ctor = try makeHeadersCtor(self);
    try env.declare("Headers", .{ .object = ctor }, true, true);
    if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
        try gb.value.object.defineData("Headers", .{ .object = ctor }, true, false, true);
}

/// Make a `.headers_method` native function flagged with `kind` (read off `"%kind%"` in dispatch) and
/// selecting `name` (the operation, via `native_name`). Proto-linked to %Function.prototype%, no own
/// `prototype` (a method).
fn makeMethod(self: *Interpreter, kind: []const u8, name: []const u8) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .headers_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try fn_obj.defineData("%kind%", .{ .string = kind }, false, false, true);
    return fn_obj;
}

/// Build the `Headers` constructor with its prototype (the multi-map methods + iterators). Sets up
/// `Headers.prototype[Symbol.iterator] === entries`.
fn makeHeadersCtor(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const proto = try Object.create(arena, self.objectProto());

    const ctor = try Object.createNative(arena, .headers_method, "Headers");
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = "Headers" }, false, false, true);
    try ctor.defineData("%kind%", .{ .string = "hdr_ctor" }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    const methods = [_][]const u8{
        "append",  "set",  "get",    "has",     "delete",
        "forEach", "keys", "values", "entries", "getSetCookie",
    };
    for (methods) |m| {
        const fn_obj = try makeMethod(self, "hdr", m);
        try proto.defineData(m, .{ .object = fn_obj }, true, false, true);
    }
    // §Headers.prototype[Symbol.iterator] === entries.
    if (self.wellKnownIterator()) |iter_sym| {
        const entries_fn = proto.get("entries").?;
        try proto.defineSymbolData(iter_sym, entries_fn, true, false, true);
    }
    return ctor;
}

// ════════════════════════════════════════════════════════════════════════════
//  dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a `.headers_method` native. `func` carries the family in `"%kind%"`; `this_val` is the
/// receiver (the new instance for the constructor, the Headers instance for a method).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const kind = if (func.get("%kind%")) |v| (if (v == .string) v.string else "") else "";
    if (std.mem.eql(u8, kind, "hdr_ctor")) return headersConstruct(self, this_val, args);
    return headersMethod(self, func.native_name, this_val, args);
}

// ════════════════════════════════════════════════════════════════════════════
//  backing store helpers ( "%hdr%" = JS Array of [lname, value] pairs )
// ════════════════════════════════════════════════════════════════════════════

/// The backing `%hdr%` array of a Headers instance (a JS Array of [lname, value] arrays).
fn hdrPairs(inst: *Object) ?*Object {
    const v = inst.get("%hdr%") orelse return null;
    return if (v == .object) v.object else null;
}

fn pairsLen(self: *Interpreter, pairs: *Object) EvalError!usize {
    const lc = try self.getProperty(.{ .object = pairs }, "length");
    if (lc.isAbrupt() or lc.normal != .number) return 0;
    return @intFromFloat(@max(lc.normal.number, 0));
}

fn pairAt(self: *Interpreter, pairs: *Object, i: usize) EvalError!?*Object {
    const ec = try self.getPropertyV(.{ .object = pairs }, .{ .number = @floatFromInt(i) });
    if (ec.isAbrupt()) return null;
    return if (ec.normal == .object) ec.normal.object else null;
}

fn pairKey(self: *Interpreter, pair: *Object) EvalError![]const u8 {
    const kc = try self.getPropertyV(.{ .object = pair }, .{ .number = 0 });
    if (kc.isAbrupt() or kc.normal != .string) return "";
    return kc.normal.string;
}
fn pairVal(self: *Interpreter, pair: *Object) EvalError![]const u8 {
    const vc = try self.getPropertyV(.{ .object = pair }, .{ .number = 1 });
    if (vc.isAbrupt() or vc.normal != .string) return "";
    return vc.normal.string;
}

/// Build a fresh [name, value] 2-element array.
fn makePair(self: *Interpreter, name: []const u8, val: []const u8) EvalError!*Object {
    const pair = try Object.createArray(self.arena, self.arrayProto());
    try pair.arraySet(self.arena, 0, .{ .string = name });
    try pair.arraySet(self.arena, 1, .{ .string = val });
    return pair;
}

/// Append a [lname, value] pair to the backing array (name is lowercased + trimmed of surrounding
/// HTTP whitespace on the value, per the fetch spec's normalize step — first cut: trim value).
fn appendPair(self: *Interpreter, pairs: *Object, lname: []const u8, val: []const u8) EvalError!void {
    const n = try pairsLen(self, pairs);
    try pairs.arraySet(self.arena, n, .{ .object = try makePair(self, lname, val) });
}

/// Lowercase `name` into the arena.
fn lower(self: *Interpreter, name: []const u8) EvalError![]const u8 {
    return std.ascii.allocLowerString(self.arena, name) catch return error.OutOfMemory;
}

/// Trim leading/trailing HTTP whitespace (tab/space/CR/LF) from a header value (the fetch
/// "normalize a header value" step).
fn normalizeValue(val: []const u8) []const u8 {
    return std.mem.trim(u8, val, "\t \r\n");
}

// ════════════════════════════════════════════════════════════════════════════
//  construction
// ════════════════════════════════════════════════════════════════════════════

/// `new Headers(init?)`: from another Headers (or any object with a `%hdr%`), an iterable of
/// `[name, value]` pairs, or a plain record of name→value entries. Names are lowercased; each entry
/// goes through `append` (so duplicates combine).
fn headersConstruct(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Headers constructor requires `new`");
    const inst = this_val.object;
    const pairs = try Object.createArray(self.arena, self.arrayProto());
    try inst.defineData("%hdr%", .{ .object = pairs }, false, false, true);

    const init: Value = if (args.len > 0) args[0] else .undefined;
    switch (init) {
        .undefined, .null => {},
        .object => |o| {
            // Another Headers (or anything carrying a `%hdr%`) → copy its [lname, value] pairs.
            if (hdrPairs(o)) |src| {
                const n = try pairsLen(self, src);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const p = (try pairAt(self, src, i)) orelse continue;
                    try appendPair(self, pairs, try pairKey(self, p), try pairVal(self, p));
                }
            } else if (try self.isArrayFromIterable(.{ .object = o })) {
                // An iterable of [name, value] pairs.
                const ir = try self.getIterator(.{ .object = o });
                const iter = switch (ir) {
                    .abrupt => |c| return c,
                    .iterator => |x| x,
                };
                while (true) {
                    const step = try self.iteratorStep(iter);
                    const entry = switch (step) {
                        .abrupt => |c| return c,
                        .done => break,
                        .value => |v| v,
                    };
                    const kc = try self.getPropertyV(entry, .{ .number = 0 });
                    if (kc.isAbrupt()) return kc;
                    const vc = try self.getPropertyV(entry, .{ .number = 1 });
                    if (vc.isAbrupt()) return vc;
                    const ks = try self.toStringValuePub(kc.normal);
                    if (ks.isAbrupt()) return ks;
                    const vs = try self.toStringValuePub(vc.normal);
                    if (vs.isAbrupt()) return vs;
                    try appendPair(self, pairs, try lower(self, ks.normal.string), normalizeValue(vs.normal.string));
                }
            } else {
                // Plain record: own enumerable string keys → ToString(values).
                var pit = o.properties.iterator();
                while (pit.next()) |e| {
                    if (!e.value_ptr.enumerable) continue;
                    const vc = try self.getProperty(.{ .object = o }, e.key_ptr.*);
                    if (vc.isAbrupt()) return vc;
                    const vs = try self.toStringValuePub(vc.normal);
                    if (vs.isAbrupt()) return vs;
                    try appendPair(self, pairs, try lower(self, e.key_ptr.*), normalizeValue(vs.normal.string));
                }
            }
        },
        else => {},
    }
    return .{ .normal = .{ .object = inst } };
}

// ════════════════════════════════════════════════════════════════════════════
//  prototype methods
// ════════════════════════════════════════════════════════════════════════════

fn argStr(self: *Interpreter, args: []const Value, i: usize) EvalError!Completion {
    return self.toStringValuePub(if (args.len > i) args[i] else .undefined);
}

fn headersMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    if (this_val != .object) return self.throwError("TypeError", "Headers method called on non-object");
    const inst = this_val.object;
    const pairs = hdrPairs(inst) orelse return self.throwError("TypeError", "not a Headers");
    const n = try pairsLen(self, pairs);

    if (eq(u8, name, "append")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const val = try argStr(self, args, 1);
        if (val.isAbrupt()) return val;
        try appendPair(self, pairs, try lower(self, key.normal.string), normalizeValue(val.normal.string));
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "set")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const val = try argStr(self, args, 1);
        if (val.isAbrupt()) return val;
        try headersSet(self, inst, try lower(self, key.normal.string), normalizeValue(val.normal.string));
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "get")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const lname = try lower(self, key.normal.string);
        // Combine ALL values for `lname` with ", " (the fetch "get" combine step).
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var found = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = (try pairAt(self, pairs, i)) orelse continue;
            if (eq(u8, try pairKey(self, p), lname)) {
                if (found) out.appendSlice(self.arena, ", ") catch return error.OutOfMemory;
                out.appendSlice(self.arena, try pairVal(self, p)) catch return error.OutOfMemory;
                found = true;
            }
        }
        if (!found) return .{ .normal = .null };
        return .{ .normal = .{ .string = out.items } };
    }
    if (eq(u8, name, "has")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        const lname = try lower(self, key.normal.string);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = (try pairAt(self, pairs, i)) orelse continue;
            if (eq(u8, try pairKey(self, p), lname)) return .{ .normal = .{ .boolean = true } };
        }
        return .{ .normal = .{ .boolean = false } };
    }
    if (eq(u8, name, "delete")) {
        const key = try argStr(self, args, 0);
        if (key.isAbrupt()) return key;
        try headersRebuildWithout(self, inst, try lower(self, key.normal.string));
        return .{ .normal = .undefined };
    }
    if (eq(u8, name, "forEach")) return headersForEach(self, inst, this_val, args);
    if (eq(u8, name, "keys")) return headersIterator(self, inst, .key);
    if (eq(u8, name, "values")) return headersIterator(self, inst, .value);
    if (eq(u8, name, "entries")) return headersIterator(self, inst, .entry);
    if (eq(u8, name, "getSetCookie")) return headersGetSetCookie(self, inst);
    return .{ .normal = .undefined };
}

/// §set: replace the FIRST occurrence of `lname`'s value and drop the rest; else append.
fn headersSet(self: *Interpreter, inst: *Object, lname: []const u8, val: []const u8) EvalError!void {
    const pairs = hdrPairs(inst).?;
    const n = try pairsLen(self, pairs);
    var found = false;
    const rebuilt = try Object.createArray(self.arena, self.arrayProto());
    var j: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        if (std.mem.eql(u8, try pairKey(self, p), lname)) {
            if (!found) {
                try rebuilt.arraySet(self.arena, j, .{ .object = try makePair(self, lname, val) });
                j += 1;
                found = true;
            }
            // drop subsequent occurrences
        } else {
            try rebuilt.arraySet(self.arena, j, .{ .object = p });
            j += 1;
        }
    }
    if (!found) try rebuilt.arraySet(self.arena, j, .{ .object = try makePair(self, lname, val) });
    try inst.defineData("%hdr%", .{ .object = rebuilt }, false, false, true);
}

fn headersRebuildWithout(self: *Interpreter, inst: *Object, lname: []const u8) EvalError!void {
    const pairs = hdrPairs(inst).?;
    const n = try pairsLen(self, pairs);
    const rebuilt = try Object.createArray(self.arena, self.arrayProto());
    var j: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        if (!std.mem.eql(u8, try pairKey(self, p), lname)) {
            try rebuilt.arraySet(self.arena, j, .{ .object = p });
            j += 1;
        }
    }
    try inst.defineData("%hdr%", .{ .object = rebuilt }, false, false, true);
}

// ── sorted, combined-by-name materialization (forEach / iterators) ──────────────

/// Build a sorted-by-name list of `[lname, value]` pairs (the fetch "sort and combine" algorithm).
/// Distinct names ascending; each name's values combined with ", " — EXCEPT `set-cookie`, which is
/// exempt from combining (each `set-cookie` value stays its own entry, in insertion order, per the
/// fetch spec). The sort is STABLE so equal-keyed set-cookie entries keep their insertion order.
fn sortedCombined(self: *Interpreter, inst: *Object) EvalError![]*Object {
    const pairs = hdrPairs(inst).?;
    const n = try pairsLen(self, pairs);

    // Distinct names in first-seen order, each accumulating its combined value. `set-cookie` is NOT
    // accumulated — each occurrence is emitted as its own entry (idx never matches it).
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var combos: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        const k = try pairKey(self, p);
        const v = try pairVal(self, p);
        const combinable = !std.mem.eql(u8, k, "set-cookie");
        var idx: ?usize = null;
        if (combinable) for (names.items, 0..) |nm, ni| if (std.mem.eql(u8, nm, k)) {
            idx = ni;
            break;
        };
        if (idx) |ix| {
            combos.items[ix].appendSlice(self.arena, ", ") catch return error.OutOfMemory;
            combos.items[ix].appendSlice(self.arena, v) catch return error.OutOfMemory;
        } else {
            names.append(self.arena, k) catch return error.OutOfMemory;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.appendSlice(self.arena, v) catch return error.OutOfMemory;
            combos.append(self.arena, buf) catch return error.OutOfMemory;
        }
    }

    // Materialize [name, combined] pairs and sort by name (byte order — names are lowercased ASCII).
    var list: std.ArrayListUnmanaged(*Object) = .empty;
    for (names.items, 0..) |nm, ni|
        list.append(self.arena, try makePair(self, nm, combos.items[ni].items)) catch return error.OutOfMemory;

    const Ctx = struct {
        interp: *Interpreter,
        fn lessThan(ctx: @This(), a: *Object, b: *Object) bool {
            const ka = pairKey(ctx.interp, a) catch "";
            const kb = pairKey(ctx.interp, b) catch "";
            return std.mem.order(u8, ka, kb) == .lt;
        }
    };
    std.mem.sort(*Object, list.items, Ctx{ .interp = self }, Ctx.lessThan);
    return list.items;
}

/// `forEach(callback[, thisArg])` — call `callback(value, name, this)` for each (combined) header in
/// sorted-by-name order.
fn headersForEach(self: *Interpreter, inst: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const cb: Value = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or !interpreter.isCallable(cb.object))
        return self.throwError("TypeError", "Callback must be a function");
    const this_arg: Value = if (args.len > 1) args[1] else .undefined;
    const list = try sortedCombined(self, inst);
    for (list) |p| {
        const k = try pairKey(self, p);
        const v = try pairVal(self, p);
        const c = try self.callFunction(cb.object, &.{ .{ .string = v }, .{ .string = k }, this_val }, this_arg);
        if (c.isAbrupt()) return c;
    }
    return .{ .normal = .undefined };
}

/// `keys()` / `values()` / `entries()` — a fresh array iterator over the sorted-combined headers.
fn headersIterator(self: *Interpreter, inst: *Object, kind: object_mod.IterKind) EvalError!Completion {
    const list = try sortedCombined(self, inst);
    const arr = try Object.createArray(self.arena, self.arrayProto());
    for (list, 0..) |p, i| {
        const k = try pairKey(self, p);
        const v = try pairVal(self, p);
        const item: Value = switch (kind) {
            .key => .{ .string = k },
            .value => .{ .string = v },
            .entry => .{ .object = try makePair(self, k, v) },
        };
        try arr.arraySet(self.arena, i, item);
    }
    return @import("interp_collection.zig").makeArrayIterator(self, .{ .object = arr }, .value);
}

/// `getSetCookie()` → an array of EACH `set-cookie` value (NOT combined — set-cookie keeps its
/// individual values per the fetch spec), or `[]` when none are present.
fn headersGetSetCookie(self: *Interpreter, inst: *Object) EvalError!Completion {
    const pairs = hdrPairs(inst).?;
    const n = try pairsLen(self, pairs);
    const arr = try Object.createArray(self.arena, self.arrayProto());
    var j: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = (try pairAt(self, pairs, i)) orelse continue;
        if (std.mem.eql(u8, try pairKey(self, p), "set-cookie")) {
            try arr.arraySet(self.arena, j, .{ .string = try pairVal(self, p) });
            j += 1;
        }
    }
    return .{ .normal = .{ .object = arr } };
}
