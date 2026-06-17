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
    if (p == .object and p.object.regexp != null) {
        pattern = p.object.regexp.?.source;
        if (f == .undefined) {
            flags = p.object.regexp.?.flags;
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
        if (rd) |r| return .{ .normal = .{ .string = r.flags } };
        if (is_proto) return .{ .normal = .{ .string = "" } };
        return it.throwError("TypeError", "Method get flags called on incompatible receiver");
    }
    // Individual flag getters → boolean (undefined on the prototype).
    if (rd) |r| {
        const b: bool = if (eql(u8, name, "global")) r.global else if (eql(u8, name, "ignoreCase")) r.ignore_case else if (eql(u8, name, "multiline")) r.multiline else if (eql(u8, name, "dotAll")) r.dot_all else if (eql(u8, name, "unicode")) r.unicode else if (eql(u8, name, "unicodeSets")) r.unicode_sets else if (eql(u8, name, "sticky")) r.sticky else r.has_indices;
        return .{ .normal = .{ .boolean = b } };
    }
    if (is_proto) return .{ .normal = .undefined };
    return it.throwError("TypeError", "RegExp flag getter called on incompatible receiver");
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
