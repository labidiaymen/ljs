//! HOST runtime (Node axis, spec 105 — NOT ECMA-262): Node's `querystring` core module —
//! `require('querystring')`. Provides `parse`/`decode`, `stringify`/`encode`, `escape`, `unescape`.
//! Installed host-only via the `host_require` core-module registry (`.qs_method` natives); never on
//! the Test262 engine surface (host core modules are not requireable there).
//!
//! Semantics mirror Node's `querystring`:
//!   • `escape(v)` — ToString(v) (throwing; a Symbol / non-callable toString → TypeError), then
//!     percent-encode every byte outside the unreserved set `A-Za-z0-9` + `!'()*-._~`. Space → `%20`
//!     (NOT `+`). A lone surrogate (invalid UTF-8) → URIError { code: ERR_INVALID_URI, "URI malformed" }.
//!   • `unescape(s)` — `+` → space, then percent-decode `%XX`; malformed escapes are left verbatim
//!     (Node's `unescape` is lenient — it never throws).
//!   • `parse(str[, sep='&'[, eq='='[, { maxKeys } ]]])` — split on `sep`, each pair on `eq`,
//!     unescape both halves (with `+`→space). Repeated keys collapse to an Array. `maxKeys` caps the
//!     number of keys (default 1000; only a NUMBER overrides — a string leaves the default; a
//!     non-finite number means unlimited; `<= 0` means unlimited). Returns a NULL-prototype object.
//!   • `stringify(obj[, sep='&'[, eq='=']])` — serialize own enumerable string keys; an Array value
//!     repeats the key per element. escape() is applied to keys and values.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

const eql = std.mem.eql;

// ── build ──────────────────────────────────────────────────────────────────────

/// Build the `querystring` module exports object (the `.core_module_cache` caller caches it).
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());
    // `decode`/`encode` are Node's aliases for `parse`/`stringify`.
    for ([_][]const u8{ "parse", "decode", "stringify", "encode", "escape", "unescape" }) |m|
        try defineMethod(self, obj, m);
    return obj;
}

fn defineMethod(self: *Interpreter, target: *Object, name: []const u8) EvalError!void {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .qs_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, true, true);
}

// ── dispatch ────────────────────────────────────────────────────────────────────

/// Dispatch a `.qs_method` native by its `native_name`.
pub fn method(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    if (eql(u8, name, "escape")) return escape(self, args);
    if (eql(u8, name, "unescape")) return unescape(self, args);
    if (eql(u8, name, "parse") or eql(u8, name, "decode")) return parse(self, args);
    if (eql(u8, name, "stringify") or eql(u8, name, "encode")) return stringify(self, args);
    return .{ .normal = .undefined };
}

// ── escape / unescape ─────────────────────────────────────────────────────────────

/// The querystring "unescaped" set: `A-Za-z0-9` plus `! ' ( ) * - . _ ~`.
fn isUnescaped(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '!', '\'', '(', ')', '*', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// `querystring.escape(v)` — ToString(v) then percent-encode. Space → `%20`. Lone surrogate → URIError.
fn escape(self: *Interpreter, args: []const Value) EvalError!Completion {
    const v: Value = if (args.len > 0) args[0] else .undefined;
    const sc = try self.toStringThrowing(v);
    if (sc.isAbrupt()) return sc;
    return percentEncode(self, sc.normal.string);
}

const HEX = "0123456789ABCDEF";
const sutf16 = @import("string_utf16.zig");

/// Percent-encode `s` (querystring rules) → a `.normal` string Completion. Walks `s` as UTF-16 code
/// units (the storage is WTF-8). Mirrors Node's `encodeStr`: a lead surrogate combines with the next
/// code unit into an astral code point (Node does NOT require the next unit to be a valid trail — it
/// just merges the low 10 bits); a lead surrogate at END of input, or a lone trail surrogate, →
/// a `.throw` URIError with Node's `code: ERR_INVALID_URI` / message "URI malformed".
fn percentEncode(self: *Interpreter, s: []const u8) EvalError!Completion {
    const arena = self.arena;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const n = sutf16.utf16Length(s);
    var i: usize = 0;
    while (i < n) {
        const cu = sutf16.codeUnitAt(s, i) orelse break;
        if (cu < 0x80) {
            const c: u8 = @intCast(cu);
            if (isUnescaped(c)) {
                out.append(arena, c) catch return error.OutOfMemory;
            } else {
                appendPercent(&out, arena, c) catch return error.OutOfMemory;
            }
            i += 1;
            continue;
        }
        var cp: u21 = cu;
        if (cu >= 0xD800 and cu <= 0xDBFF) {
            // Lead surrogate: must have a following code unit (Node merges its low 10 bits).
            if (i + 1 >= n) return uriMalformed(self);
            const next = sutf16.codeUnitAt(s, i + 1) orelse return uriMalformed(self);
            cp = 0x10000 + (@as(u21, cu & 0x3FF) << 10) + @as(u21, next & 0x3FF);
            i += 2;
        } else if (cu >= 0xDC00 and cu <= 0xDFFF) {
            // A lone trail surrogate (no preceding lead) is malformed.
            return uriMalformed(self);
        } else {
            i += 1;
        }
        // UTF-8 encode `cp` and percent-escape each byte.
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return uriMalformed(self);
        for (buf[0..len]) |b| appendPercent(&out, arena, b) catch return error.OutOfMemory;
    }
    return .{ .normal = .{ .string = out.items } };
}

fn appendPercent(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, b: u8) !void {
    try out.append(arena, '%');
    try out.append(arena, HEX[b >> 4]);
    try out.append(arena, HEX[b & 0x0f]);
}

/// Throw a Node-style URIError with `code: "ERR_INVALID_URI"` and message "URI malformed".
fn uriMalformed(self: *Interpreter) EvalError!Completion {
    const arena = self.arena;
    const err = try Object.create(arena, self.errorProto("URIError"));
    err.error_data = true;
    try err.set("name", .{ .string = "URIError" });
    try err.set("message", .{ .string = "URI malformed" });
    try err.defineData("code", .{ .string = "ERR_INVALID_URI" }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// `querystring.unescape(s)` — lenient percent-decode (`+` → space, `%XX` → byte; malformed verbatim).
fn unescape(self: *Interpreter, args: []const Value) EvalError!Completion {
    const v: Value = if (args.len > 0) args[0] else .undefined;
    const sc = try self.toStringThrowing(v);
    if (sc.isAbrupt()) return sc;
    return .{ .normal = .{ .string = try percentDecode(self.arena, sc.normal.string) } };
}

/// Percent-decode `s` with `+`→space. Malformed escapes (a `%` not followed by two hex digits) are
/// left verbatim (matches Node's lenient `unescape`). Arena-owned.
fn percentDecode(arena: std.mem.Allocator, s: []const u8) EvalError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            out.append(arena, ' ') catch return error.OutOfMemory;
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                out.append(arena, (hi.? << 4) | lo.?) catch return error.OutOfMemory;
                i += 3;
            } else {
                out.append(arena, c) catch return error.OutOfMemory;
                i += 1;
            }
        } else {
            out.append(arena, c) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.items;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ── parse ─────────────────────────────────────────────────────────────────────────

/// `querystring.parse(str[, sep[, eq[, options]]])` → a NULL-prototype object of key → value(s).
fn parse(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;

    // The result is a null-prototype object (Node: `ObjectCreate(null)`).
    const obj = try Object.create(arena, null);

    const str_v: Value = if (args.len > 0) args[0] else .undefined;
    if (str_v != .string or str_v.string.len == 0) return .{ .normal = .{ .object = obj } };
    const str = str_v.string;

    const sep = try optSep(self, if (args.len > 1) args[1] else .undefined, "&");
    if (sep.isAbrupt()) return sep;
    const eq = try optSep(self, if (args.len > 2) args[2] else .undefined, "=");
    if (eq.isAbrupt()) return eq;
    const sep_s = sep.normal.string;
    const eq_s = eq.normal.string;

    // maxKeys: default 1000; only a NUMBER overrides (a string leaves the default). A non-finite or
    // `<= 0` number means unlimited.
    var max_keys: usize = 1000;
    var unlimited = false;
    if (args.len > 3 and args[3] == .object) {
        if (args[3].object.get("maxKeys")) |mk| {
            if (mk == .number) {
                const n = mk.number;
                if (std.math.isNan(n) or std.math.isInf(n) or n <= 0) {
                    unlimited = true;
                } else {
                    max_keys = @intFromFloat(@min(n, @as(f64, @floatFromInt(std.math.maxInt(usize)))));
                }
            }
        }
    }

    var key_count: usize = 0;
    var it = splitBy(str, sep_s);
    while (it.next()) |seg| {
        if (!unlimited and key_count >= max_keys) break;
        if (seg.len == 0) continue;
        var key_raw: []const u8 = seg;
        var val_raw: []const u8 = "";
        if (indexOfStr(seg, eq_s)) |e| {
            key_raw = seg[0..e];
            val_raw = seg[e + eq_s.len ..];
        }
        const key = try percentDecode(arena, key_raw);
        const val = try percentDecode(arena, val_raw);
        try appendKv(self, obj, key, val);
        key_count += 1;
    }
    return .{ .normal = .{ .object = obj } };
}

/// Add `key=val` to the result object: first occurrence → string; a repeated key collapses to an
/// Array (appending subsequent values).
fn appendKv(self: *Interpreter, obj: *Object, key: []const u8, val: []const u8) EvalError!void {
    const arena = self.arena;
    if (obj.get(key)) |existing| {
        if (existing == .object and existing.object.kind == .array) {
            const arr = existing.object;
            try arr.arraySet(arena, arr.array_length, .{ .string = val });
        } else {
            // Promote the scalar to a 2-element array.
            const arr = Object.createArray(arena, self.arrayProto()) catch return error.OutOfMemory;
            try arr.arraySet(arena, 0, existing);
            try arr.arraySet(arena, 1, .{ .string = val });
            try obj.defineData(key, .{ .object = arr }, true, true, true);
        }
    } else {
        try obj.defineData(key, .{ .string = val }, true, true, true);
    }
}

// ── stringify ─────────────────────────────────────────────────────────────────────

/// `querystring.stringify(obj[, sep[, eq]])` — serialize own enumerable string keys. An Array value
/// repeats the key per element.
fn stringify(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const obj_v: Value = if (args.len > 0) args[0] else .undefined;

    const sep = try optSep(self, if (args.len > 1) args[1] else .undefined, "&");
    if (sep.isAbrupt()) return sep;
    const eq = try optSep(self, if (args.len > 2) args[2] else .undefined, "=");
    if (eq.isAbrupt()) return eq;
    const sep_s = sep.normal.string;
    const eq_s = eq.normal.string;

    if (obj_v != .object) return .{ .normal = .{ .string = "" } };
    const obj = obj_v.object;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;

    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const pv = entry.value_ptr.*;
        if (!pv.enumerable or pv.payload != .data) continue;
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '%') continue; // skip hidden host state
        const ek_c = try percentEncode(self, key);
        if (ek_c.isAbrupt()) return ek_c;
        const ek = ek_c.normal.string;
        const value = pv.payload.data;

        if (value == .object and value.object.kind == .array) {
            // Repeat the key per element (an empty array contributes nothing).
            const arr = value.object;
            const n = arr.array_length;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const ev = try scalarStr(self, arr.arrayGet(i));
                if (ev.isAbrupt()) return ev;
                const pev = try percentEncode(self, ev.normal.string);
                if (pev.isAbrupt()) return pev;
                try emitPair(arena, &out, &first, sep_s, eq_s, ek, pev.normal.string);
            }
        } else {
            const sv = try scalarStr(self, value);
            if (sv.isAbrupt()) return sv;
            const psv = try percentEncode(self, sv.normal.string);
            if (psv.isAbrupt()) return psv;
            try emitPair(arena, &out, &first, sep_s, eq_s, ek, psv.normal.string);
        }
    }
    return .{ .normal = .{ .string = out.items } };
}

fn emitPair(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, sep: []const u8, eq: []const u8, key: []const u8, val: []const u8) EvalError!void {
    if (!first.*) out.appendSlice(arena, sep) catch return error.OutOfMemory;
    first.* = false;
    out.appendSlice(arena, key) catch return error.OutOfMemory;
    out.appendSlice(arena, eq) catch return error.OutOfMemory;
    out.appendSlice(arena, val) catch return error.OutOfMemory;
}

/// Coerce a stringify value to its serialized string: string/number/boolean → String(v); everything
/// else (object/null/undefined/symbol) → "" (matching Node's `stringifyPrimitive`).
fn scalarStr(self: *Interpreter, v: Value) EvalError!Completion {
    return switch (v) {
        .string, .number, .boolean => self.toStringValuePub(v),
        else => .{ .normal = .{ .string = "" } },
    };
}

// ── helpers ─────────────────────────────────────────────────────────────────────

/// Coerce an optional `sep`/`eq` argument to its string, defaulting to `dflt` when undefined/"".
fn optSep(self: *Interpreter, v: Value, dflt: []const u8) EvalError!Completion {
    if (v == .undefined or v == .null) return .{ .normal = .{ .string = dflt } };
    const sc = try self.toStringValuePub(v);
    if (sc.isAbrupt()) return sc;
    if (sc.normal.string.len == 0) return .{ .normal = .{ .string = dflt } };
    return sc;
}

/// First index of the (possibly multi-char) substring `needle` in `hay`, or null.
fn indexOfStr(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    return std.mem.indexOf(u8, hay, needle);
}

/// Split `s` on the (possibly multi-char) delimiter `sep`. A single-char sep uses a scalar splitter.
const StrSplit = struct {
    s: []const u8,
    sep: []const u8,
    done: bool = false,

    fn next(self: *StrSplit) ?[]const u8 {
        if (self.done) return null;
        if (std.mem.indexOf(u8, self.s, self.sep)) |idx| {
            const seg = self.s[0..idx];
            self.s = self.s[idx + self.sep.len ..];
            return seg;
        }
        self.done = true;
        return self.s;
    }
};

fn splitBy(s: []const u8, sep: []const u8) StrSplit {
    return .{ .s = s, .sep = sep };
}
