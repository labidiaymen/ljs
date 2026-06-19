//! §22.2.6 the %RegExp.prototype% well-known-Symbol methods (`[Symbol.match]`, `[Symbol.matchAll]`,
//! `[Symbol.replace]`, `[Symbol.search]`, `[Symbol.split]`) plus the §22.2.7 abstract operations they
//! rest on (RegExpExec honoring an overridden `exec`, AdvanceStringIndex, GetSubstitution) and the
//! §22.2.9 %RegExpStringIteratorPrototype%. Dispatched from `callNative` via `.regexp_symbol_method`
//! and `.regexp_string_iterator_next`. These methods are GENERIC over a RegExp-like `this` (they read
//! `exec`/`flags`/`global`/`unicode`/`lastIndex` as ordinary properties), so they also drive
//! `String.prototype.{match,matchAll,replace,replaceAll,search,split}`'s @@-delegation.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const builtin_regexp = @import("builtin_regexp.zig");

const isCallable = interp.isCallable;

// ── shared helpers ───────────────────────────────────────────────────────────

fn toLen(n: f64) usize {
    if (n <= 0 or std.math.isNan(n)) return 0;
    if (n >= 9007199254740991.0) return 9007199254740991;
    return @intFromFloat(n);
}

/// §22.2.7.4 AdvanceStringIndex — bump `index` by 1, or by 2 when `unicode` and `index` sits on the
/// lead of a surrogate pair (storage is WTF-8 here, so a code point ≥ U+10000 occupies a 4-byte
/// sequence; advancing past the whole sequence is the byte-domain analogue).
fn advanceStringIndex(s: []const u8, index: usize, unicode: bool) usize {
    if (!unicode or index >= s.len) return index + 1;
    const b = s[index];
    const seq_len: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    return index + seq_len;
}

/// §7.3.4 Set(O, "lastIndex", v, true) — the THROWING form the RegExp methods require. A silent
/// no-op (sloppy-mode ordinary [[Set]] on a non-writable lastIndex) would otherwise leave lastIndex
/// unadvanced and spin the global match/replace loop forever.
fn setLastIndexThrow(it: *Interpreter, base: Value, v: Value) EvalError!Completion {
    if (base == .object and base.object.proxy == null) {
        return it.setKeyThrow(base.object, "lastIndex", v);
    }
    return it.setProperty(base, "lastIndex", v);
}

/// Read a boolean-coerced property off `this` (the spec's `ToBoolean(Get(rx, "global"))` etc.).
fn getFlagBool(it: *Interpreter, this_val: Value, name: []const u8) EvalError!union(enum) { ok: bool, abrupt: Completion } {
    const c = try it.getProperty2(this_val, name);
    if (c.isAbrupt()) return .{ .abrupt = c };
    return .{ .ok = @import("abstract_ops.zig").toBoolean(c.normal) };
}

/// §22.2.7.1 RegExpExec ( R, S ) — read `R.exec`; if callable, call it (validating its result is
/// Object|Null) and return that; otherwise fall back to the builtin exec (§22.2.7.2).
fn regExpExec(it: *Interpreter, r: Value, s: []const u8) EvalError!Completion {
    const exec_c = try it.getProperty2(r, "exec");
    if (exec_c.isAbrupt()) return exec_c;
    if (exec_c.normal == .object and isCallable(exec_c.normal.object)) {
        const res = try it.callFunction(exec_c.normal.object, &.{.{ .string = s }}, r);
        if (res.isAbrupt()) return res;
        if (res.normal != .object and res.normal != .null) {
            return it.throwError("TypeError", "RegExp exec method must return an Object or null");
        }
        return res;
    }
    // Fall back to %RegExp.prototype.exec% — requires a real RegExp [[RegExpMatcher]].
    if (r != .object or r.object.regexp == null) {
        return it.throwError("TypeError", "RegExpExec called on incompatible receiver");
    }
    return builtin_regexp.exec(it, r, &.{.{ .string = s }});
}

// ── §22.2.6.12 RegExp.prototype [ @@search ] ────────────────────────────────

fn search(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "RegExp.prototype[Symbol.search] requires an object");
    const sc = try it.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;

    // Save lastIndex, reset to 0, run exec, restore lastIndex.
    const prev = try it.getProperty2(this_val, "lastIndex");
    if (prev.isAbrupt()) return prev;
    if (!sameValueZeroNum(prev.normal, 0)) {
        const setc = try setLastIndexThrow(it, this_val, .{ .number = 0 });
        if (setc.isAbrupt()) return setc;
    }
    const res = try regExpExec(it, this_val, s);
    if (res.isAbrupt()) return res;
    const cur = try it.getProperty2(this_val, "lastIndex");
    if (cur.isAbrupt()) return cur;
    if (!sameValue(cur.normal, prev.normal)) {
        const setc = try setLastIndexThrow(it, this_val, prev.normal);
        if (setc.isAbrupt()) return setc;
    }
    if (res.normal == .null) return .{ .normal = .{ .number = -1 } };
    return it.getProperty2(res.normal, "index");
}

fn sameValueZeroNum(v: Value, n: f64) bool {
    return v == .number and v.number == n;
}
fn sameValue(a: Value, b: Value) bool {
    if (a == .number and b == .number) return a.number == b.number or (std.math.isNan(a.number) and std.math.isNan(b.number));
    return std.meta.eql(a, b);
}

// ── §22.2.6.8 RegExp.prototype [ @@match ] ──────────────────────────────────

fn match(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "RegExp.prototype[Symbol.match] requires an object");
    const sc = try it.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;

    const gflag = try getFlagBool(it, this_val, "global");
    const global = switch (gflag) {
        .ok => |b| b,
        .abrupt => |c| return c,
    };
    if (!global) {
        return regExpExec(it, this_val, s);
    }
    // Global: collect every match's [0] string; reset lastIndex to 0 first.
    const uflag = try getFlagBool(it, this_val, "unicode");
    const full_unicode = switch (uflag) {
        .ok => |b| b,
        .abrupt => |c| return c,
    };
    const setc = try setLastIndexThrow(it, this_val, .{ .number = 0 });
    if (setc.isAbrupt()) return setc;

    const arr = (try it.newArray(0)).normal.object;
    var n: usize = 0;
    while (true) {
        const res = try regExpExec(it, this_val, s);
        if (res.isAbrupt()) return res;
        if (res.normal == .null) {
            if (n == 0) return .{ .normal = .null };
            return .{ .normal = .{ .object = arr } };
        }
        const m0c = try it.getProperty2(res.normal, "0");
        if (m0c.isAbrupt()) return m0c;
        const mstrc = try it.toStringValuePub(m0c.normal);
        if (mstrc.isAbrupt()) return mstrc;
        const matchStr = mstrc.normal.string;
        try arr.arraySet(it.arena, n, .{ .string = matchStr });
        if (matchStr.len == 0) {
            const lic = try it.getProperty2(this_val, "lastIndex");
            if (lic.isAbrupt()) return lic;
            const nic = try it.toIntegerOrInfinity(lic.normal);
            if (nic.isAbrupt()) return nic;
            const next = advanceStringIndex(s, toLen(nic.normal.number), full_unicode);
            const sc2 = try setLastIndexThrow(it, this_val, .{ .number = @floatFromInt(next) });
            if (sc2.isAbrupt()) return sc2;
        }
        n += 1;
    }
}

// ── §22.2.6.9 RegExp.prototype [ @@matchAll ] + §22.2.9 RegExpStringIterator ──

fn matchAll(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "RegExp.prototype[Symbol.matchAll] requires an object");
    const sc = try it.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;

    // §22.2.6.9: construct a fresh RegExp matcher (same source/flags), copy lastIndex, then build the
    // iterator over it. We construct via the species constructor to honor subclassing minimally.
    const ctor_c = try speciesConstructor(it, this_val.object);
    if (ctor_c.isAbrupt()) return ctor_c;
    const flags_c = try it.getProperty2(this_val, "flags");
    if (flags_c.isAbrupt()) return flags_c;
    const flags_s = try it.toStringValuePub(flags_c.normal);
    if (flags_s.isAbrupt()) return flags_s;
    if (ctor_c.normal != .object) return it.throwError("TypeError", "not a constructor");
    const matcher_c = try it.construct(ctor_c.normal.object, &.{ this_val, flags_c.normal });
    if (matcher_c.isAbrupt()) return matcher_c;
    const matcher = matcher_c.normal;

    const li_c = try it.getProperty2(this_val, "lastIndex");
    if (li_c.isAbrupt()) return li_c;
    const li_n = try it.toIntegerOrInfinity(li_c.normal);
    if (li_n.isAbrupt()) return li_n;
    const set_c = try setLastIndexThrow(it, matcher, .{ .number = li_n.normal.number });
    if (set_c.isAbrupt()) return set_c;

    const global = blk: {
        const fl = flags_s.normal.string;
        break :blk std.mem.indexOfScalar(u8, fl, 'g') != null;
    };
    const full_unicode = blk: {
        const fl = flags_s.normal.string;
        break :blk std.mem.indexOfScalar(u8, fl, 'u') != null or std.mem.indexOfScalar(u8, fl, 'v') != null;
    };
    return makeRegExpStringIterator(it, matcher, s, global, full_unicode);
}

/// §22.2.9.1 CreateRegExpStringIterator. State is held in own non-enumerable data properties on the
/// opaque iterator object (the [[…]] slots): the matcher, the string, the global / fullUnicode flags,
/// and a `##done` marker.
fn makeRegExpStringIterator(it: *Interpreter, matcher: Value, s: []const u8, global: bool, full_unicode: bool) EvalError!Completion {
    const iter = try Object.create(it.arena, it.iteratorProto());
    try iter.defineData("##rx", matcher, true, false, true);
    try iter.defineData("##str", .{ .string = s }, true, false, true);
    try iter.defineData("##global", .{ .boolean = global }, true, false, true);
    try iter.defineData("##unicode", .{ .boolean = full_unicode }, true, false, true);
    try iter.defineData("##done", .{ .boolean = false }, true, false, true);
    const next_fn = try Object.createNative(it.arena, .regexp_string_iterator_next, "next");
    next_fn.prototype = it.functionProto();
    try iter.defineData("next", .{ .object = next_fn }, true, false, true);
    if (it.wellKnownIterator()) |iter_sym| {
        const self_fn = try Object.createNative(it.arena, .generator_iterator, "[Symbol.iterator]");
        self_fn.prototype = it.functionProto();
        try iter.defineSymbolData(iter_sym, .{ .object = self_fn }, true, false, true);
    }
    return .{ .normal = .{ .object = iter } };
}

/// §22.2.9.2.1 %RegExpStringIteratorPrototype%.next.
pub fn stringIteratorNext(it: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "not a RegExp String Iterator");
    const o = this_val.object;
    const done_v = o.get("##done") orelse return it.throwError("TypeError", "not a RegExp String Iterator");
    if (done_v == .boolean and done_v.boolean) return iterResult(it, .undefined, true);

    const rx = o.get("##rx").?;
    const str_v = o.get("##str").?;
    const s = if (str_v == .string) str_v.string else "";
    const global_v = o.get("##global").?;
    const global = global_v == .boolean and global_v.boolean;
    const unicode_v = o.get("##unicode").?;
    const full_unicode = unicode_v == .boolean and unicode_v.boolean;

    const res = try regExpExec(it, rx, s);
    if (res.isAbrupt()) return res;
    if (res.normal == .null) {
        try o.defineData("##done", .{ .boolean = true }, true, false, true);
        return iterResult(it, .undefined, true);
    }
    if (!global) {
        try o.defineData("##done", .{ .boolean = true }, true, false, true);
        return iterResult(it, res.normal, false);
    }
    // Global: if match[0] is empty, advance lastIndex so we don't loop forever.
    const m0c = try it.getProperty2(res.normal, "0");
    if (m0c.isAbrupt()) return m0c;
    const mstrc = try it.toStringValuePub(m0c.normal);
    if (mstrc.isAbrupt()) return mstrc;
    if (mstrc.normal.string.len == 0) {
        const lic = try it.getProperty2(rx, "lastIndex");
        if (lic.isAbrupt()) return lic;
        const nic = try it.toIntegerOrInfinity(lic.normal);
        if (nic.isAbrupt()) return nic;
        const next = advanceStringIndex(s, toLen(nic.normal.number), full_unicode);
        const sc2 = try setLastIndexThrow(it, rx, .{ .number = @floatFromInt(next) });
        if (sc2.isAbrupt()) return sc2;
    }
    return iterResult(it, res.normal, false);
}

fn iterResult(it: *Interpreter, value: Value, done: bool) EvalError!Completion {
    const o = try Object.create(it.arena, it.objectProto());
    try o.defineData("value", value, true, true, true);
    try o.defineData("done", .{ .boolean = done }, true, true, true);
    return .{ .normal = .{ .object = o } };
}

// ── §22.2.6.14 RegExp.prototype [ @@split ] ─────────────────────────────────

fn split(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "RegExp.prototype[Symbol.split] requires an object");
    const rx = this_val.object;
    const sc = try it.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;

    // SpeciesConstructor → build a sticky splitter so each exec starts exactly at the cursor.
    const ctor_c = try speciesConstructor(it, rx);
    if (ctor_c.isAbrupt()) return ctor_c;
    const flags_c = try it.getProperty2(this_val, "flags");
    if (flags_c.isAbrupt()) return flags_c;
    const flags_s = (try it.toStringValuePub(flags_c.normal));
    if (flags_s.isAbrupt()) return flags_s;
    const flags = flags_s.normal.string;
    const unicode_matching = std.mem.indexOfScalar(u8, flags, 'u') != null or std.mem.indexOfScalar(u8, flags, 'v') != null;
    const new_flags: []const u8 = if (std.mem.indexOfScalar(u8, flags, 'y') != null)
        flags
    else
        try std.fmt.allocPrint(it.arena, "{s}y", .{flags});
    if (ctor_c.normal != .object) return it.throwError("TypeError", "not a constructor");
    const splitter_c = try it.construct(ctor_c.normal.object, &.{ this_val, .{ .string = new_flags } });
    if (splitter_c.isAbrupt()) return splitter_c;
    const splitter = splitter_c.normal;

    const lim_v: Value = if (args.len > 1) args[1] else .undefined;
    const limit: u64 = if (lim_v == .undefined) 0xFFFFFFFF else blk: {
        const lc = try it.toIntegerOrInfinity(lim_v);
        if (lc.isAbrupt()) return lc;
        const ln = lc.normal.number;
        break :blk @as(u64, @intFromFloat(@mod(@max(ln, 0), 4294967296.0)));
    };

    const arr = (try it.newArray(0)).normal.object;
    if (limit == 0) return .{ .normal = .{ .object = arr } };
    if (s.len == 0) {
        const z = try regExpExec(it, splitter, s);
        if (z.isAbrupt()) return z;
        if (z.normal != .null) return .{ .normal = .{ .object = arr } };
        try arr.arraySet(it.arena, 0, .{ .string = s });
        return .{ .normal = .{ .object = arr } };
    }

    var arr_len: usize = 0;
    var p: usize = 0; // last split end
    var q: usize = 0; // cursor
    while (q < s.len) {
        const set_c = try setLastIndexThrow(it, splitter, .{ .number = @floatFromInt(q) });
        if (set_c.isAbrupt()) return set_c;
        const z = try regExpExec(it, splitter, s);
        if (z.isAbrupt()) return z;
        if (z.normal == .null) {
            q = advanceStringIndex(s, q, unicode_matching);
            continue;
        }
        const li_c = try it.getProperty2(splitter, "lastIndex");
        if (li_c.isAbrupt()) return li_c;
        const li_n = try it.toIntegerOrInfinity(li_c.normal);
        if (li_n.isAbrupt()) return li_n;
        const e = @min(toLen(li_n.normal.number), s.len);
        if (e == p) {
            q = advanceStringIndex(s, q, unicode_matching);
            continue;
        }
        try arr.arraySet(it.arena, arr_len, .{ .string = s[p..q] });
        arr_len += 1;
        if (arr_len == limit) return .{ .normal = .{ .object = arr } };
        // Append captured groups 1..numberOfCaptures.
        const ncap_c = try it.getProperty2(z.normal, "length");
        if (ncap_c.isAbrupt()) return ncap_c;
        const ncap_n = try it.toIntegerOrInfinity(ncap_c.normal);
        if (ncap_n.isAbrupt()) return ncap_n;
        const ncap: usize = if (toLen(ncap_n.normal.number) == 0) 0 else toLen(ncap_n.normal.number) - 1;
        var i: usize = 1;
        while (i <= ncap) : (i += 1) {
            const key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
            const cap_c = try it.getProperty2(z.normal, key);
            if (cap_c.isAbrupt()) return cap_c;
            try arr.arraySet(it.arena, arr_len, cap_c.normal);
            arr_len += 1;
            if (arr_len == limit) return .{ .normal = .{ .object = arr } };
        }
        p = e;
        q = p;
    }
    try arr.arraySet(it.arena, arr_len, .{ .string = s[p..] });
    return .{ .normal = .{ .object = arr } };
}

// ── §22.2.6.11 RegExp.prototype [ @@replace ] ───────────────────────────────

fn replace(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "RegExp.prototype[Symbol.replace] requires an object");
    const sc = try it.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    const replace_val: Value = if (args.len > 1) args[1] else .undefined;
    const functional = replace_val == .object and isCallable(replace_val.object);
    var repl_str: []const u8 = "";
    if (!functional) {
        const rc = try it.toStringValuePub(replace_val);
        if (rc.isAbrupt()) return rc;
        repl_str = rc.normal.string;
    }

    const gflag = try getFlagBool(it, this_val, "global");
    const global = switch (gflag) {
        .ok => |b| b,
        .abrupt => |c| return c,
    };
    var full_unicode = false;
    if (global) {
        const uflag = try getFlagBool(it, this_val, "unicode");
        full_unicode = switch (uflag) {
            .ok => |b| b,
            .abrupt => |c| return c,
        };
        const setc = try setLastIndexThrow(it, this_val, .{ .number = 0 });
        if (setc.isAbrupt()) return setc;
    }

    // Collect all results (one for non-global).
    var results: std.ArrayListUnmanaged(Value) = .empty;
    while (true) {
        const res = try regExpExec(it, this_val, s);
        if (res.isAbrupt()) return res;
        if (res.normal == .null) break;
        try results.append(it.arena, res.normal);
        if (!global) break;
        const m0c = try it.getProperty2(res.normal, "0");
        if (m0c.isAbrupt()) return m0c;
        const mstrc = try it.toStringValuePub(m0c.normal);
        if (mstrc.isAbrupt()) return mstrc;
        if (mstrc.normal.string.len == 0) {
            const lic = try it.getProperty2(this_val, "lastIndex");
            if (lic.isAbrupt()) return lic;
            const nic = try it.toIntegerOrInfinity(lic.normal);
            if (nic.isAbrupt()) return nic;
            const next = advanceStringIndex(s, toLen(nic.normal.number), full_unicode);
            const sc2 = try setLastIndexThrow(it, this_val, .{ .number = @floatFromInt(next) });
            if (sc2.isAbrupt()) return sc2;
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var next_source_pos: usize = 0;
    for (results.items) |result| {
        // nCaptures = max(length - 1, 0)
        const len_c = try it.getProperty2(result, "length");
        if (len_c.isAbrupt()) return len_c;
        const len_n = try it.toIntegerOrInfinity(len_c.normal);
        if (len_n.isAbrupt()) return len_n;
        const len_i = toLen(len_n.normal.number);
        const n_captures: usize = if (len_i == 0) 0 else len_i - 1;

        const m0c = try it.getProperty2(result, "0");
        if (m0c.isAbrupt()) return m0c;
        const matched_c = try it.toStringValuePub(m0c.normal);
        if (matched_c.isAbrupt()) return matched_c;
        const matched = matched_c.normal.string;

        const pos_c = try it.getProperty2(result, "index");
        if (pos_c.isAbrupt()) return pos_c;
        const pos_n = try it.toIntegerOrInfinity(pos_c.normal);
        if (pos_n.isAbrupt()) return pos_n;
        const position = @min(@max(toLen2(pos_n.normal.number), 0), s.len);

        // Gather captures (as Value: string or undefined).
        var captures: std.ArrayListUnmanaged(Value) = .empty;
        var i: usize = 1;
        while (i <= n_captures) : (i += 1) {
            const key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
            const cap_c = try it.getProperty2(result, key);
            if (cap_c.isAbrupt()) return cap_c;
            if (cap_c.normal == .undefined) {
                try captures.append(it.arena, .undefined);
            } else {
                const csc = try it.toStringValuePub(cap_c.normal);
                if (csc.isAbrupt()) return csc;
                try captures.append(it.arena, .{ .string = csc.normal.string });
            }
        }

        // named groups object
        const groups_c = try it.getProperty2(result, "groups");
        if (groups_c.isAbrupt()) return groups_c;
        const named = groups_c.normal;

        var replacement: []const u8 = "";
        if (functional) {
            // call(replaceValue, undefined, «matched, ...captures, position, S[, namedGroups]»)
            var call_args: std.ArrayListUnmanaged(Value) = .empty;
            try call_args.append(it.arena, .{ .string = matched });
            for (captures.items) |c| try call_args.append(it.arena, c);
            try call_args.append(it.arena, .{ .number = @floatFromInt(position) });
            try call_args.append(it.arena, .{ .string = s });
            if (named != .undefined) try call_args.append(it.arena, named);
            const rc = try it.callFunction(replace_val.object, call_args.items, .undefined);
            if (rc.isAbrupt()) return rc;
            const rsc = try it.toStringValuePub(rc.normal);
            if (rsc.isAbrupt()) return rsc;
            replacement = rsc.normal.string;
        } else {
            const gs = try getSubstitution(it, matched, s, position, captures.items, named, repl_str);
            if (gs.isAbrupt()) return gs;
            replacement = gs.normal.string;
        }

        if (position >= next_source_pos) {
            try out.appendSlice(it.arena, s[next_source_pos..position]);
            try out.appendSlice(it.arena, replacement);
            next_source_pos = position + matched.len;
        }
    }
    if (next_source_pos < s.len) try out.appendSlice(it.arena, s[next_source_pos..]);
    return .{ .normal = .{ .string = out.items } };
}

fn toLen2(n: f64) usize {
    if (n <= 0 or std.math.isNan(n)) return 0;
    if (n >= 9007199254740991.0) return 9007199254740991;
    return @intFromFloat(n);
}

/// §22.2.7.5 GetSubstitution — expand `$$ $& $\` $' $n $nn $<name>` in `replacement`. `captures`
/// holds the 1-based capture strings (string | undefined); `named` is the groups object or undefined.
fn getSubstitution(it: *Interpreter, matched: []const u8, s: []const u8, position: usize, captures: []const Value, named: Value, replacement: []const u8) EvalError!Completion {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const tail_pos = position + matched.len;
    var i: usize = 0;
    while (i < replacement.len) {
        const c = replacement[i];
        if (c != '$' or i + 1 >= replacement.len) {
            try out.append(it.arena, c);
            i += 1;
            continue;
        }
        const n = replacement[i + 1];
        switch (n) {
            '$' => {
                try out.append(it.arena, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(it.arena, matched);
                i += 2;
            },
            '`' => {
                try out.appendSlice(it.arena, s[0..position]);
                i += 2;
            },
            '\'' => {
                try out.appendSlice(it.arena, if (tail_pos < s.len) s[tail_pos..] else "");
                i += 2;
            },
            '0'...'9' => {
                // $n or $nn — prefer two digits when valid.
                var consumed: usize = 0;
                var idx: usize = 0;
                const d1: usize = n - '0';
                // Try two-digit
                if (i + 2 < replacement.len and replacement[i + 2] >= '0' and replacement[i + 2] <= '9') {
                    const two = d1 * 10 + (replacement[i + 2] - '0');
                    if (two >= 1 and two <= captures.len) {
                        idx = two;
                        consumed = 3;
                    }
                }
                if (consumed == 0 and d1 >= 1 and d1 <= captures.len) {
                    idx = d1;
                    consumed = 2;
                }
                if (consumed == 0) {
                    try out.append(it.arena, '$');
                    i += 1;
                } else {
                    const cap = captures[idx - 1];
                    if (cap == .string) try out.appendSlice(it.arena, cap.string);
                    i += consumed;
                }
            },
            '<' => {
                // $<name> — named capture. If there are no named groups (named is undefined), $< is literal.
                if (named == .undefined) {
                    try out.append(it.arena, '$');
                    i += 1;
                } else {
                    const close = std.mem.indexOfScalarPos(u8, replacement, i + 2, '>');
                    if (close == null) {
                        try out.append(it.arena, '$');
                        i += 1;
                    } else {
                        const name = replacement[i + 2 .. close.?];
                        const gc = try it.getProperty2(named, name);
                        if (gc.isAbrupt()) return gc;
                        if (gc.normal != .undefined) {
                            const gsc = try it.toStringValuePub(gc.normal);
                            if (gsc.isAbrupt()) return gsc;
                            try out.appendSlice(it.arena, gsc.normal.string);
                        }
                        i = close.? + 1;
                    }
                }
            },
            else => {
                try out.append(it.arena, '$');
                i += 1;
            },
        }
    }
    return .{ .normal = .{ .string = out.items } };
}

// ── §22.2.5.2 / §7.3.22 SpeciesConstructor(O, %RegExp%) ─────────────────────

fn speciesConstructor(it: *Interpreter, o: *Object) EvalError!Completion {
    // C = O.constructor; if undefined → default %RegExp%.
    const ctor_c = try it.getProperty2(.{ .object = o }, "constructor");
    if (ctor_c.isAbrupt()) return ctor_c;
    if (ctor_c.normal == .undefined) return defaultRegExpCtor(it);
    if (ctor_c.normal != .object) return it.throwError("TypeError", "constructor is not an object");
    // S = C[Symbol.species]; null/undefined → default %RegExp%.
    const species = it.wellKnownSymbol("species") orelse return .{ .normal = ctor_c.normal };
    const sc = try it.getSymbolProperty(ctor_c.normal, species);
    if (sc.isAbrupt()) return sc;
    if (sc.normal == .undefined or sc.normal == .null) return .{ .normal = ctor_c.normal };
    if (sc.normal != .object or !isCallable(sc.normal.object)) {
        return it.throwError("TypeError", "Symbol.species is not a constructor");
    }
    return .{ .normal = sc.normal };
}

fn defaultRegExpCtor(it: *Interpreter) EvalError!Completion {
    const g = it.globals orelse return it.throwError("TypeError", "no realm");
    const b = g.lookup("RegExp") orelse return it.throwError("TypeError", "no RegExp");
    return .{ .normal = b.value };
}

// ── dispatch ─────────────────────────────────────────────────────────────────

/// callNative entry for `.regexp_symbol_method` — `native_name` is the Symbol method's identity.
pub fn method(it: *Interpreter, native_name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    if (eql(u8, native_name, "[Symbol.match]")) return match(it, this_val, args);
    if (eql(u8, native_name, "[Symbol.matchAll]")) return matchAll(it, this_val, args);
    if (eql(u8, native_name, "[Symbol.replace]")) return replace(it, this_val, args);
    if (eql(u8, native_name, "[Symbol.search]")) return search(it, this_val, args);
    if (eql(u8, native_name, "[Symbol.split]")) return split(it, this_val, args);
    return it.throwError("TypeError", "unknown RegExp Symbol method");
}
