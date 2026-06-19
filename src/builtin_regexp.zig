//! §22.2 RegExp — the constructor, `makeRegExp` (used by both `new RegExp` and regex literals), the
//! %RegExp.prototype% accessor getters (source/flags/global/ignoreCase/multiline/dotAll/unicode/
//! unicodeSets/sticky/hasIndices), and toString. Dispatched from the interpreter's `callNative`.
//! M1: parsing + metadata only — the pattern matcher (exec/test) + Symbol methods follow.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const RegExpData = object_mod.RegExpData;
const engine = @import("builtin_regexp_engine.zig");

/// %RegExp.prototype% — the [[Prototype]] of every RegExp instance. Null in a realm-less eval.
fn regexpProto(it: *Interpreter) ?*Object {
    const g = it.globals orelse return null;
    const b = g.lookup("RegExp") orelse return null;
    if (b.value != .object) return null;
    const pv = b.value.object.get("prototype") orelse return null;
    return if (pv == .object) pv.object else null;
}

/// §22.2.3.1 RegExpInitialize (M-subset): parse `flags`, build a fresh RegExp object over `pattern`.
/// Invalid/duplicate flags (or `u`+`v` together) → SyntaxError. `source` is the pattern with empty → "(?:)".
pub fn makeRegExp(it: *Interpreter, pattern: []const u8, flags: []const u8) EvalError!Completion {
    var rd = RegExpData{ .source = "", .flags = "" }; // set below once parsed
    for (flags) |f| {
        const dup = switch (f) {
            'd' => blk: {
                defer rd.has_indices = true;
                break :blk rd.has_indices;
            },
            'g' => blk: {
                defer rd.global = true;
                break :blk rd.global;
            },
            'i' => blk: {
                defer rd.ignore_case = true;
                break :blk rd.ignore_case;
            },
            'm' => blk: {
                defer rd.multiline = true;
                break :blk rd.multiline;
            },
            's' => blk: {
                defer rd.dot_all = true;
                break :blk rd.dot_all;
            },
            'u' => blk: {
                defer rd.unicode = true;
                break :blk rd.unicode;
            },
            'v' => blk: {
                defer rd.unicode_sets = true;
                break :blk rd.unicode_sets;
            },
            'y' => blk: {
                defer rd.sticky = true;
                break :blk rd.sticky;
            },
            else => return it.throwError("SyntaxError", "Invalid regular expression flags"),
        };
        if (dup) return it.throwError("SyntaxError", "Invalid regular expression flags");
    }
    if (rd.unicode and rd.unicode_sets) return it.throwError("SyntaxError", "Invalid regular expression flags: u and v");

    // Canonical flag order d,g,i,m,s,u,v,y (§22.2.3.4 get flags).
    var fbuf: std.ArrayListUnmanaged(u8) = .empty;
    if (rd.has_indices) try fbuf.append(it.arena, 'd');
    if (rd.global) try fbuf.append(it.arena, 'g');
    if (rd.ignore_case) try fbuf.append(it.arena, 'i');
    if (rd.multiline) try fbuf.append(it.arena, 'm');
    if (rd.dot_all) try fbuf.append(it.arena, 's');
    if (rd.unicode) try fbuf.append(it.arena, 'u');
    if (rd.unicode_sets) try fbuf.append(it.arena, 'v');
    if (rd.sticky) try fbuf.append(it.arena, 'y');
    rd.flags = fbuf.items;
    rd.source = if (pattern.len == 0) "(?:)" else pattern;

    // §22.2.3.1 step: parse the pattern (validates syntax → SyntaxError) and keep the compiled program.
    const prog = engine.compile(it.arena, pattern, rd.ignore_case, rd.multiline, rd.dot_all, rd.unicode or rd.unicode_sets) catch |e| switch (e) {
        error.SyntaxError => return it.throwError("SyntaxError", "Invalid regular expression"),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const prog_ptr = try it.arena.create(engine.Program);
    prog_ptr.* = prog;
    rd.program = prog_ptr;

    const rd_ptr = try it.arena.create(RegExpData);
    rd_ptr.* = rd;
    const o = try Object.create(it.arena, regexpProto(it));
    o.regexp = rd_ptr;
    // §22.2.6.13 `lastIndex` — an own writable, non-enumerable, non-configurable data property.
    try o.defineData("lastIndex", .{ .number = 0 }, true, false, false);
    return .{ .normal = .{ .object = o } };
}

/// §22.2.4.1 RegExp ( pattern, flags ) — constructor and plain call both build a RegExp. If `pattern`
/// is already a RegExp, reuse its source (and its flags when `flags` is omitted).
pub fn construct(it: *Interpreter, args: []const Value) EvalError!Completion {
    const p: Value = if (args.len > 0) args[0] else .undefined;
    const f: Value = if (args.len > 1) args[1] else .undefined;
    var pattern: []const u8 = "";
    var flags: []const u8 = "";
    // §22.2.4.1 step 1: patternIsRegExp = IsRegExp(pattern) (reads pattern[@@match] — may throw).
    const pattern_is_regexp = try isRegExp(it, p);
    if (pattern_is_regexp.isAbrupt()) return pattern_is_regexp;
    if (p == .object and p.object.regexp != null) {
        // step 3 (native RegExp): reuse the [[OriginalSource]]/[[OriginalFlags]] internal slots.
        pattern = p.object.regexp.?.source;
        if (f == .undefined) {
            flags = p.object.regexp.?.flags;
        } else {
            const fc = try it.toStringValuePub(f);
            if (fc.isAbrupt()) return fc;
            flags = fc.normal.string;
        }
    } else if (pattern_is_regexp.normal.boolean) {
        // step 6 (RegExp-like, no [[RegExpMatcher]]): P = Get(pattern,"source"); F = flags ?? Get(pattern,"flags").
        const pc = try it.getProperty2(p, "source");
        if (pc.isAbrupt()) return pc;
        const psc = try it.toStringValuePub(pc.normal);
        if (psc.isAbrupt()) return psc;
        pattern = psc.normal.string;
        if (f == .undefined) {
            const fc = try it.getProperty2(p, "flags");
            if (fc.isAbrupt()) return fc;
            const fsc = try it.toStringValuePub(fc.normal);
            if (fsc.isAbrupt()) return fsc;
            flags = fsc.normal.string;
        } else {
            const fc = try it.toStringValuePub(f);
            if (fc.isAbrupt()) return fc;
            flags = fc.normal.string;
        }
    } else {
        if (p != .undefined) {
            const pc = try it.toStringValuePub(p);
            if (pc.isAbrupt()) return pc;
            pattern = pc.normal.string;
        }
        if (f != .undefined) {
            const fc = try it.toStringValuePub(f);
            if (fc.isAbrupt()) return fc;
            flags = fc.normal.string;
        }
    }
    // "(?:)" is the canonical empty source; a literal RegExp object reuses its stored "(?:)" as-is.
    if (std.mem.eql(u8, pattern, "(?:)")) pattern = "";
    return makeRegExp(it, pattern, flags);
}

// ── §22.2.5.2 RegExp.escape ( S ) + §22.2.5.2.1 EncodeForRegExpEscape ──────────

fn isSyntaxChar(cp: u21) bool {
    return switch (cp) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}
fn isRegExpWhiteSpaceOrLT(cp: u21) bool {
    return switch (cp) {
        0x0A,
        0x0D,
        0x2028,
        0x2029, // LineTerminator
        0x09,
        0x0B,
        0x0C,
        0x20,
        0xA0,
        0x1680,
        0xFEFF, // WhiteSpace
        0x2000...0x200A,
        0x202F,
        0x205F,
        0x3000,
        => true,
        else => false,
    };
}
fn otherPunctuator(cp: u21) bool {
    return switch (cp) {
        ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => true,
        else => false,
    };
}

/// Append `\xNN` / `\uNNNN` escapes for a code point that must be hex-escaped. ≤0xFF → `\xNN`; else
/// each UTF-16 code unit as `\uNNNN` (a code point ≥ U+10000 emits two surrogate `\u` escapes).
fn appendHexEscape(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, cp: u21) std.mem.Allocator.Error!void {
    if (cp <= 0xFF) {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\x{x:0>2}", .{cp}));
        return;
    }
    if (cp <= 0xFFFF) {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{cp}));
        return;
    }
    const v = cp - 0x10000;
    const hi: u16 = @intCast(0xD800 + (v >> 10));
    const lo: u16 = @intCast(0xDC00 + (v & 0x3FF));
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{x:0>4}\\u{x:0>4}", .{ hi, lo }));
}

/// §22.2.5.2.1 EncodeForRegExpEscape — append the escaped form of `cp` to `out`.
fn encodeForRegExpEscape(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, cp: u21) std.mem.Allocator.Error!void {
    if (isSyntaxChar(cp) or cp == '/') {
        try out.append(arena, '\\');
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        try out.appendSlice(arena, buf[0..n]);
        return;
    }
    // Table 64 ControlEscape.
    const ctrl: ?u8 = switch (cp) {
        0x09 => 't',
        0x0A => 'n',
        0x0B => 'v',
        0x0C => 'f',
        0x0D => 'r',
        else => null,
    };
    if (ctrl) |ce| {
        try out.append(arena, '\\');
        try out.append(arena, ce);
        return;
    }
    if (otherPunctuator(cp) or isRegExpWhiteSpaceOrLT(cp)) {
        try appendHexEscape(out, arena, cp);
        return;
    }
    // Default: emit the code point verbatim.
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
    try out.appendSlice(arena, buf[0..n]);
}

/// §22.2.5.2 RegExp.escape ( S ) — S must be a String (else TypeError). The first code point, if an
/// ASCII alphanumeric, is hex-escaped (`\xNN`); every code point then goes through EncodeForRegExpEscape.
pub fn escape(it: *Interpreter, args: []const Value) EvalError!Completion {
    const s: Value = if (args.len > 0) args[0] else .undefined;
    if (s != .string) return it.throwError("TypeError", "RegExp.escape requires a string");
    const str = s.string;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var first = true;
    while (i < str.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const end = @min(i + seq_len, str.len);
        const cp: u21 = std.unicode.utf8Decode(str[i..end]) catch str[i];
        if (first and ((cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z'))) {
            try appendHexEscape(&out, it.arena, cp);
        } else {
            try encodeForRegExpEscape(&out, it.arena, cp);
        }
        first = false;
        i = end;
    }
    return .{ .normal = .{ .string = out.items } };
}

/// §22.2.7.2 (legacy §7.2.8) IsRegExp ( argument ): not an Object → false; read `argument[@@match]`
/// (may throw) → if not undefined, ToBoolean(it); else true iff `argument` has a [[RegExpMatcher]].
/// Returned as a Completion whose normal payload is a boolean (or an abrupt throw).
fn isRegExp(it: *Interpreter, v: Value) EvalError!Completion {
    if (v != .object) return .{ .normal = .{ .boolean = false } };
    if (it.wellKnownSymbol("match")) |sym| {
        const mc = try it.getSymbolProperty(v, sym);
        if (mc.isAbrupt()) return mc;
        if (mc.normal != .undefined) {
            return .{ .normal = .{ .boolean = @import("abstract_ops.zig").toBoolean(mc.normal) } };
        }
    }
    return .{ .normal = .{ .boolean = v.object.regexp != null } };
}

/// §22.2.6 the %RegExp.prototype% accessor getters. On the prototype object itself (no [[RegExpMatcher]])
/// the spec returns "(?:)" for source, "" for flags, and undefined for each flag getter.
pub fn getter(it: *Interpreter, name: []const u8, this_val: Value) EvalError!Completion {
    const eql = std.mem.eql;
    const rd: ?*RegExpData = if (this_val == .object) this_val.object.regexp else null;
    const is_proto = this_val == .object and this_val.object == regexpProto(it);

    if (eql(u8, name, "source")) {
        if (rd) |r| return .{ .normal = .{ .string = r.source } };
        if (is_proto) return .{ .normal = .{ .string = "(?:)" } };
        return it.throwError("TypeError", "Method get source called on incompatible receiver");
    }
    if (eql(u8, name, "flags")) {
        // §22.2.6.4 get flags — GENERIC: requires an Object receiver, then reads each flag property
        // (`hasIndices`/`global`/…) and ToBoolean-coerces it, in the canonical d,g,i,m,s,u,v,y order.
        if (this_val != .object) return it.throwError("TypeError", "Method get flags called on incompatible receiver");
        const pairs = [_]struct { prop: []const u8, ch: u8 }{
            .{ .prop = "hasIndices", .ch = 'd' },
            .{ .prop = "global", .ch = 'g' },
            .{ .prop = "ignoreCase", .ch = 'i' },
            .{ .prop = "multiline", .ch = 'm' },
            .{ .prop = "dotAll", .ch = 's' },
            .{ .prop = "unicode", .ch = 'u' },
            .{ .prop = "unicodeSets", .ch = 'v' },
            .{ .prop = "sticky", .ch = 'y' },
        };
        var fbuf: std.ArrayListUnmanaged(u8) = .empty;
        for (pairs) |p| {
            const c = try it.getProperty2(this_val, p.prop);
            if (c.isAbrupt()) return c;
            if (@import("abstract_ops.zig").toBoolean(c.normal)) try fbuf.append(it.arena, p.ch);
        }
        return .{ .normal = .{ .string = fbuf.items } };
    }
    // Individual flag getters → boolean (undefined on the prototype).
    if (rd) |r| {
        const b: bool = if (eql(u8, name, "global")) r.global else if (eql(u8, name, "ignoreCase")) r.ignore_case else if (eql(u8, name, "multiline")) r.multiline else if (eql(u8, name, "dotAll")) r.dot_all else if (eql(u8, name, "unicode")) r.unicode else if (eql(u8, name, "unicodeSets")) r.unicode_sets else if (eql(u8, name, "sticky")) r.sticky else r.has_indices;
        return .{ .normal = .{ .boolean = b } };
    }
    if (is_proto) return .{ .normal = .undefined };
    return it.throwError("TypeError", "RegExp flag getter called on incompatible receiver");
}

/// §22.2.7.2 RegExpBuiltinExec — the core match: read `lastIndex` (for global/sticky), run the
/// compiled program from there, then either build the match result array (`[whole, ...groups]` with
/// `index`/`input`/`groups`) and advance `lastIndex`, or return null and reset `lastIndex` to 0.
fn builtinExec(it: *Interpreter, this_val: Value, input: []const u8) EvalError!Completion {
    const o = this_val.object;
    const rd = o.regexp.?;
    const prog = rd.program orelse return it.throwError("TypeError", "RegExp has no compiled pattern");
    const global_or_sticky = rd.global or rd.sticky;

    var last_index: usize = 0;
    if (global_or_sticky) {
        const lic = try it.getProperty2(this_val, "lastIndex");
        if (lic.isAbrupt()) return lic;
        const nic = try it.toIntegerOrInfinity(lic.normal);
        if (nic.isAbrupt()) return nic;
        const n = nic.normal.number;
        if (n < 0 or n > @as(f64, @floatFromInt(input.len))) {
            const sc = try it.setKeyThrow(this_val.object, "lastIndex", .{ .number = 0 });
            if (sc.isAbrupt()) return sc;
            return .{ .normal = .null };
        }
        last_index = @intFromFloat(n);
    }

    const m = (try engine.exec(it.arena, prog, input, last_index, rd.sticky)) orelse {
        if (global_or_sticky) {
            const sc = try it.setKeyThrow(this_val.object, "lastIndex", .{ .number = 0 });
            if (sc.isAbrupt()) return sc;
        }
        return .{ .normal = .null };
    };

    const start = m.saves[0].?;
    const end = m.saves[1].?;
    if (global_or_sticky) {
        const sc = try it.setKeyThrow(this_val.object, "lastIndex", .{ .number = @floatFromInt(end) });
        if (sc.isAbrupt()) return sc;
    }

    const arr = (try it.newArray(prog.num_groups + 1)).normal.object;
    try arr.arraySet(it.arena, 0, .{ .string = input[start..end] });
    var gi: usize = 1;
    while (gi <= prog.num_groups) : (gi += 1) {
        const a = m.saves[2 * gi];
        const b = m.saves[2 * gi + 1];
        const v: Value = if (a != null and b != null) .{ .string = input[a.?..b.?] } else .undefined;
        try arr.arraySet(it.arena, gi, v);
    }
    try arr.defineData("index", .{ .number = @floatFromInt(start) }, true, true, true);
    try arr.defineData("input", .{ .string = input }, true, true, true);
    // §22.2.7.2: `groups` is a null-prototype object of named captures, or undefined when there are none.
    if (prog.names.len > 0) {
        const groups = try Object.create(it.arena, null);
        for (prog.names) |ng| {
            const a = m.saves[2 * ng.index];
            const b = m.saves[2 * ng.index + 1];
            const v: Value = if (a != null and b != null) .{ .string = input[a.?..b.?] } else .undefined;
            try groups.defineData(ng.name, v, true, true, true);
        }
        try arr.defineData("groups", .{ .object = groups }, true, true, true);
    } else {
        try arr.defineData("groups", .undefined, true, true, true);
    }
    // §22.2.7.2 step 34 + §22.2.7.7 MakeMatchIndicesIndexPairArray — the `d` flag adds an `indices`
    // array of [start,end] pairs (undefined for unmatched groups) plus `indices.groups` for named caps.
    if (rd.has_indices) {
        const indices = (try it.newArray(prog.num_groups + 1)).normal.object;
        try setIndexPair(it, indices, 0, m.saves[0], m.saves[1]);
        var ig: usize = 1;
        while (ig <= prog.num_groups) : (ig += 1) {
            try setIndexPair(it, indices, ig, m.saves[2 * ig], m.saves[2 * ig + 1]);
        }
        if (prog.names.len > 0) {
            const igroups = try Object.create(it.arena, null);
            for (prog.names) |ng| {
                const a = m.saves[2 * ng.index];
                const b = m.saves[2 * ng.index + 1];
                const v: Value = if (a != null and b != null) try pairArray(it, a.?, b.?) else .undefined;
                try igroups.defineData(ng.name, v, true, true, true);
            }
            try indices.defineData("groups", .{ .object = igroups }, true, true, true);
        } else {
            try indices.defineData("groups", .undefined, true, true, true);
        }
        try arr.defineData("indices", .{ .object = indices }, true, true, true);
    }
    return .{ .normal = .{ .object = arr } };
}

fn pairArray(it: *Interpreter, a: usize, b: usize) EvalError!Value {
    const pair = (try it.newArray(2)).normal.object;
    try pair.arraySet(it.arena, 0, .{ .number = @floatFromInt(a) });
    try pair.arraySet(it.arena, 1, .{ .number = @floatFromInt(b) });
    return .{ .object = pair };
}

fn setIndexPair(it: *Interpreter, indices: *Object, i: usize, a: ?usize, b: ?usize) EvalError!void {
    const v: Value = if (a != null and b != null) try pairArray(it, a.?, b.?) else .undefined;
    try indices.arraySet(it.arena, i, v);
}

/// §22.2.6.2 RegExp.prototype.exec ( string ) — coerce `string`, then run the builtin exec.
pub fn exec(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.regexp == null) {
        return it.throwError("TypeError", "RegExp.prototype.exec called on incompatible receiver");
    }
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    const sc = try it.toStringValuePub(arg);
    if (sc.isAbrupt()) return sc;
    return builtinExec(it, this_val, sc.normal.string);
}

/// §22.2.6.16 RegExp.prototype.test ( string ) — exec and report whether a match was found.
pub fn test_(it: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object or this_val.object.regexp == null) {
        return it.throwError("TypeError", "RegExp.prototype.test called on incompatible receiver");
    }
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    const sc = try it.toStringValuePub(arg);
    if (sc.isAbrupt()) return sc;
    const r = try builtinExec(it, this_val, sc.normal.string);
    if (r.isAbrupt()) return r;
    return .{ .normal = .{ .boolean = r.normal != .null } };
}

/// §22.2.6.17 RegExp.prototype.toString → `/source/flags` (reads the `source`/`flags` properties).
pub fn toString(it: *Interpreter, this_val: Value) EvalError!Completion {
    if (this_val != .object) return it.throwError("TypeError", "RegExp.prototype.toString requires an object");
    const sc = try it.getProperty2(this_val, "source");
    if (sc.isAbrupt()) return sc;
    const fc = try it.getProperty2(this_val, "flags");
    if (fc.isAbrupt()) return fc;
    const src = if (sc.normal == .string) sc.normal.string else "";
    const flg = if (fc.normal == .string) fc.normal.string else "";
    return .{ .normal = .{ .string = try std.fmt.allocPrint(it.arena, "/{s}/{s}", .{ src, flg }) } };
}
