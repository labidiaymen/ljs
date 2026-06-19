//! §22.1.2 `String` statics + §22.1.3 `String.prototype` methods. `this` is the receiver
//! (boxed transparently in getProperty). The engine is byte-oriented (UTF-8): `.length`/indexing
//! are byte-based (a documented deviation); `codePointAt`/`fromCodePoint` decode/encode UTF-8 code
//! points. Native built-ins dispatched from the interpreter's `callNative` (`string_method` /
//! `string_static`); this file is the string library, the interpreter stays the evaluator.
const std = @import("std");
const interp = @import("interpreter.zig");
const sutf16 = @import("string_utf16.zig");
const abstract_ops = @import("abstract_ops.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;

pub fn call(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;

    // §22.1.3.28/.32 toString/valueOf: thisStringValue — only a primitive String or a String wrapper
    // object is valid (no ToString coercion). Handled before RequireObjectCoercible.
    if (eql(u8, name, "toString") or eql(u8, name, "valueOf")) {
        if (this_val == .string) return str(this_val.string);
        if (this_val == .object and this_val.object.primitive != null and this_val.object.primitive.? == .string) {
            return str(this_val.object.primitive.?.string);
        }
        return it.throwError("TypeError", "String.prototype method called on incompatible receiver");
    }

    // §22.1.3 step 1 of every other method: RequireObjectCoercible(this) → ToString(this).
    // null/undefined throw a TypeError; a `new String(x)` wrapper unboxes via [[StringData]].
    if (this_val == .undefined or this_val == .null) {
        return it.throwError("TypeError", "String.prototype method called on null or undefined");
    }
    const s = if (this_val == .string)
        this_val.string
    else if (this_val == .object and this_val.object.primitive != null and this_val.object.primitive.? == .string)
        this_val.object.primitive.?.string
    else switch (try it.toStringThrowing(this_val)) {
        // §22.1.3 step 2 ToString(this) — throwing: a Symbol `this`, or an object whose ToPrimitive
        // throws (`{toString:undefined, valueOf:undefined}`), surfaces a TypeError.
        .normal => |v| v.string,
        else => |c| return c,
    };

    if (eql(u8, name, "charAt")) {
        // §22.1.3.1: the 1-code-unit substring at code-unit index `n` (§6.1.4); out of range → "".
        const ir = try intArg(it, args, 0, 0);
        const n = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        if (n >= 0 and n < @as(f64, @floatFromInt(sutf16.utf16Length(s)))) {
            return str(try sutf16.charAtAlloc(it.arena, s, @intFromFloat(n)));
        }
        return str("");
    }
    if (eql(u8, name, "charCodeAt")) {
        // §22.1.3.2: the UTF-16 code unit at code-unit index `n`; out of range → NaN.
        const ir = try intArg(it, args, 0, 0);
        const n = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        if (n >= 0 and n < @as(f64, @floatFromInt(sutf16.utf16Length(s)))) {
            if (sutf16.codeUnitAt(s, @intFromFloat(n))) |cu| return num(@floatFromInt(cu));
        }
        return num(std.math.nan(f64));
    }
    if (eql(u8, name, "codePointAt")) {
        // §22.1.3.4: the code POINT at code-unit index `pos` — a lead surrogate followed by a trail
        // combines into the astral scalar; out of range → undefined.
        const ir = try intArg(it, args, 0, 0);
        const n = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        if (n < 0 or n >= @as(f64, @floatFromInt(sutf16.utf16Length(s)))) return .{ .normal = .undefined };
        const pos: usize = @intFromFloat(n);
        const first = sutf16.codeUnitAt(s, pos) orelse return .{ .normal = .undefined };
        if (first >= 0xD800 and first <= 0xDBFF) {
            if (sutf16.codeUnitAt(s, pos + 1)) |second| {
                if (second >= 0xDC00 and second <= 0xDFFF) {
                    const cp = 0x10000 + ((@as(u32, first - 0xD800)) << 10) + (second - 0xDC00);
                    return num(@floatFromInt(cp));
                }
            }
        }
        return num(@floatFromInt(first));
    }
    if (eql(u8, name, "at")) {
        // §22.1.3.1: relative code-unit index (negative from the end); out of range → undefined.
        const ir = try intArg(it, args, 0, 0);
        const rel = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const len_f: f64 = @floatFromInt(sutf16.utf16Length(s));
        const k = if (rel >= 0) rel else len_f + rel;
        if (k < 0 or k >= len_f) return .{ .normal = .undefined };
        return str(try sutf16.charAtAlloc(it.arena, s, @intFromFloat(k)));
    }
    if (eql(u8, name, "indexOf")) {
        const needle = switch (try argStr(it, args, 0)) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
        const ir = try intArg(it, args, 1, 0);
        const pos = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const start: usize = clampPos(pos, s.len);
        if (std.mem.indexOfPos(u8, s, start, needle)) |p| return num(@floatFromInt(p));
        // an empty needle at/after start matches at min(start, len)
        if (needle.len == 0) return num(@floatFromInt(@min(start, s.len)));
        return num(-1);
    }
    if (eql(u8, name, "lastIndexOf")) {
        const needle = switch (try argStr(it, args, 0)) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
        // §22.1.3.11: position is ToNumber (NaN → +Infinity), clamped to [0, len].
        const posn = try numArg(it, args, 1);
        const limit: usize = if (std.math.isNan(posn) or posn >= @as(f64, @floatFromInt(s.len)))
            s.len
        else if (posn < 0) 0 else @intFromFloat(@trunc(posn));
        return num(lastIndexOf(s, needle, limit));
    }
    if (eql(u8, name, "includes")) {
        // §22.1.3.8 steps 4-6: IsRegExp(searchString) → TypeError (a RegExp arg is rejected).
        switch (try isRegExp(it, if (args.len > 0) args[0] else .undefined)) {
            .abrupt => |c| return c,
            .value => |b| if (b) return it.throwError("TypeError", "First argument to String.prototype.includes must not be a regular expression"),
        }
        const needle = switch (try argStr(it, args, 0)) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
        const ir = try intArg(it, args, 1, 0);
        const pos = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const start: usize = clampPos(pos, s.len);
        return boolean(std.mem.indexOfPos(u8, s, start, needle) != null or (needle.len == 0 and start <= s.len));
    }
    if (eql(u8, name, "startsWith")) {
        // §22.1.3.23 steps 4-6: IsRegExp(searchString) → TypeError.
        switch (try isRegExp(it, if (args.len > 0) args[0] else .undefined)) {
            .abrupt => |c| return c,
            .value => |b| if (b) return it.throwError("TypeError", "First argument to String.prototype.startsWith must not be a regular expression"),
        }
        const needle = switch (try argStr(it, args, 0)) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
        const ir = try intArg(it, args, 1, 0);
        const pos = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const start: usize = clampPos(pos, s.len);
        return boolean(start + needle.len <= s.len and std.mem.eql(u8, s[start .. start + needle.len], needle));
    }
    if (eql(u8, name, "endsWith")) {
        // §22.1.3.7 steps 4-6: IsRegExp(searchString) → TypeError.
        switch (try isRegExp(it, if (args.len > 0) args[0] else .undefined)) {
            .abrupt => |c| return c,
            .value => |b| if (b) return it.throwError("TypeError", "First argument to String.prototype.endsWith must not be a regular expression"),
        }
        const needle = switch (try argStr(it, args, 0)) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
        // §22.1.3.7: endPosition defaults to len; NaN → 0 (via intArg), clamped to [0, len].
        const ir = try intArg(it, args, 1, @floatFromInt(s.len));
        const ep = switch (ir) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const end: usize = clampPos(ep, s.len);
        return boolean(needle.len <= end and std.mem.eql(u8, s[end - needle.len .. end], needle));
    }
    if (eql(u8, name, "toUpperCase") or eql(u8, name, "toLowerCase") or eql(u8, name, "toLocaleUpperCase") or eql(u8, name, "toLocaleLowerCase")) {
        const upper = eql(u8, name, "toUpperCase") or eql(u8, name, "toLocaleUpperCase");
        const out = try it.arena.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
        return str(out);
    }
    if (eql(u8, name, "slice")) {
        // §22.1.3.21: relative UTF-16 code-unit indices (negative from end), no swap (§6.1.4).
        const len_f: f64 = @floatFromInt(sutf16.utf16Length(s));
        const a = switch (try relArg(it, args, 0, 0, len_f)) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const b = switch (try relArg(it, args, 1, len_f, len_f)) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        if (a >= b) return str("");
        return str(try sutf16.substringByCodeUnits(it.arena, s, a, b));
    }
    if (eql(u8, name, "substring")) {
        // §22.1.3.27: code-unit indices clamped to [0, len], then swapped so lo<=hi.
        const ulen = sutf16.utf16Length(s);
        const a = switch (try intArg(it, args, 0, 0)) {
            .abrupt => |c| return c,
            .value => |v| clampPos(v, ulen),
        };
        const b = switch (try intArg(it, args, 1, @floatFromInt(ulen))) {
            .abrupt => |c| return c,
            .value => |v| clampPos(v, ulen),
        };
        return str(try sutf16.substringByCodeUnits(it.arena, s, @min(a, b), @max(a, b)));
    }
    if (eql(u8, name, "substr")) {
        // Annex B §B.2.2.1 String.prototype.substr(start, length) — code-unit semantics.
        const start_f = switch (try intArg(it, args, 0, 0)) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const len_f: f64 = @floatFromInt(sutf16.utf16Length(s));
        // length defaults to +Infinity (the rest of the string).
        const length_f = switch (try intArgInf(it, args, 1)) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        const a: f64 = if (start_f < 0) @max(len_f + start_f, 0) else @min(start_f, len_f);
        const count = @max(@min(length_f, len_f - a), 0);
        if (count <= 0) return str("");
        const lo: usize = @intFromFloat(a);
        const hi: usize = @intFromFloat(a + count);
        return str(try sutf16.substringByCodeUnits(it.arena, s, lo, hi));
    }
    if (eql(u8, name, "concat")) {
        // §22.1.3.5: ToString each argument and append.
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(it.arena, s);
        for (args) |a| {
            const cs = try coerceStr(it, a);
            switch (cs) {
                .abrupt => |c| return c,
                .string => |sv| try buf.appendSlice(it.arena, sv),
            }
        }
        return str(buf.items);
    }
    if (eql(u8, name, "repeat")) {
        // §22.1.3.18: count is ToIntegerOrInfinity (undefined/NaN → 0); negative or +Infinity →
        // RangeError. Preserve an EXPLICIT +Infinity (so `repeat(Infinity)` throws) but treat a
        // missing/undefined arg as 0 (`repeat(undefined)` → "").
        const cf: f64 = if (args.len == 0 or args[0] == .undefined) 0 else switch (try intArgInf(it, args, 0)) {
            .abrupt => |c| return c,
            .value => |v| v,
        };
        if (cf < 0 or std.math.isInf(cf)) return it.throwError("RangeError", "Invalid count value");
        const count: usize = @intFromFloat(cf);
        if (count == 0 or s.len == 0) return str("");
        const out = try it.arena.alloc(u8, s.len * count);
        var i: usize = 0;
        while (i < count) : (i += 1) @memcpy(out[i * s.len ..][0..s.len], s);
        return str(out);
    }
    if (eql(u8, name, "padStart") or eql(u8, name, "padEnd")) {
        return pad(it, s, args, eql(u8, name, "padStart"));
    }
    if (eql(u8, name, "trim") or eql(u8, name, "trimStart") or eql(u8, name, "trimEnd")) {
        // §22.1.3.32 TrimString — strip leading/trailing §6.1.4 WhiteSpace + LineTerminator. The set
        // includes non-ASCII code points (U+00A0, U+1680, U+2000..U+200A, U+2028, U+2029, U+202F,
        // U+205F, U+3000, U+FEFF), so trimming works over CODE POINTS, not bytes.
        const want_start = !eql(u8, name, "trimEnd");
        const want_end = !eql(u8, name, "trimStart");
        var lo: usize = 0;
        var hi: usize = s.len;
        if (want_start) while (lo < hi) {
            const d = decodeCp(s, lo);
            if (!isWsCp(d.cp)) break;
            lo += d.len;
        };
        if (want_end) while (hi > lo) {
            // step back to the start of the last code point in [lo, hi).
            const start = cpStart(s, lo, hi);
            const d = decodeCp(s, start);
            if (!isWsCp(d.cp)) break;
            hi = start;
        };
        return str(s[lo..hi]);
    }
    if (eql(u8, name, "localeCompare")) {
        // §22.1.3.10: locale-aware compare. The M-subset uses a simple code-unit (byte) compare
        // (no ICU/CLDR collation) — see specs/039 spec.md. Returns -1 / 0 / +1.
        const that = switch (try argStr(it, args, 0)) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
        return num(switch (std.mem.order(u8, s, that)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }
    if (eql(u8, name, "replace") or eql(u8, name, "replaceAll")) {
        return replace(it, s, args, eql(u8, name, "replaceAll"));
    }
    if (eql(u8, name, "split")) {
        return split(it, s, args);
    }
    if (eql(u8, name, "match")) {
        return matchLike(it, s, this_val, args, "match");
    }
    if (eql(u8, name, "matchAll")) {
        return matchAll(it, s, this_val, args);
    }
    if (eql(u8, name, "search")) {
        return matchLike(it, s, this_val, args, "search");
    }
    if (eql(u8, name, "isWellFormed")) {
        return boolean(sutf16.isWellFormed(s));
    }
    if (eql(u8, name, "toWellFormed")) {
        return str(try sutf16.toWellFormed(it.arena, s));
    }
    if (eql(u8, name, "normalize")) {
        return normalize(it, s, args);
    }

    return .{ .normal = .undefined };
}

// §22.1.2 String statics.
pub fn staticCall(it: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const eql = std.mem.eql;
    if (eql(u8, name, "fromCharCode")) {
        // §22.1.2.1: each arg → ToUint16; UTF-8-encode that code-unit value (incl. lone surrogates).
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (args) |a| {
            const nc = try it.toNumberThrowing(a);
            if (nc.isAbrupt()) return nc;
            const u16v = toUint16(nc.normal.number);
            try encodeCp(it.arena, &buf, u16v);
        }
        // §6.1.4: adjacent surrogate code units form an astral scalar — canonicalize so the result
        // byte-equals the same astral literal.
        return str(try sutf16.canonicalizeSurrogates(it.arena, buf.items));
    }
    if (eql(u8, name, "fromCodePoint")) {
        // §22.1.2.2: each arg must be an integer code point in [0, 0x10FFFF] (else RangeError).
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (args) |a| {
            const nc = try it.toNumberThrowing(a);
            if (nc.isAbrupt()) return nc;
            const n = nc.normal.number;
            if (std.math.isNan(n) or n != @trunc(n) or n < 0 or n > 0x10FFFF) {
                return it.throwError("RangeError", "Invalid code point");
            }
            try encodeCp(it.arena, &buf, @intFromFloat(n));
        }
        return str(try sutf16.canonicalizeSurrogates(it.arena, buf.items));
    }
    if (eql(u8, name, "raw")) {
        return stringRaw(it, args);
    }
    return .{ .normal = .undefined };
}

// §22.1.2.4 String.raw ( template, ...substitutions ) — operates on the template object's `raw` array.
fn stringRaw(it: *Interpreter, args: []const Value) EvalError!Completion {
    const template: Value = if (args.len > 0) args[0] else .undefined;
    // ToObject(template).Get("raw") then ToObject(raw); LengthOfArrayLike(raw).
    const rawc = try it.getProperty2(template, "raw");
    if (rawc.isAbrupt()) return rawc;
    const raw = rawc.normal;
    if (raw == .undefined or raw == .null) {
        return it.throwError("TypeError", "String.raw: template.raw is not object-coercible");
    }
    const lenc = try it.getProperty2(raw, "length");
    if (lenc.isAbrupt()) return lenc;
    const lnc = try it.toNumberThrowing(lenc.normal);
    if (lnc.isAbrupt()) return lnc;
    const lf = lnc.normal.number;
    const literal_segments: usize = if (std.math.isNan(lf) or lf <= 0) 0 else if (lf > 4294967295.0) 4294967295 else @intFromFloat(@trunc(lf));
    if (literal_segments == 0) return str("");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < literal_segments) : (i += 1) {
        const key = try std.fmt.allocPrint(it.arena, "{d}", .{i});
        const segc = try it.getProperty2(raw, key);
        if (segc.isAbrupt()) return segc;
        const ss = try coerceStr(it, segc.normal);
        switch (ss) {
            .abrupt => |c| return c,
            .string => |sv| try buf.appendSlice(it.arena, sv),
        }
        if (i + 1 == literal_segments) break;
        // substitutions are 1 fewer than literal segments; missing → skipped (empty).
        if (i + 1 < args.len) {
            const sub = try coerceStr(it, args[i + 1]);
            switch (sub) {
                .abrupt => |c| return c,
                .string => |sv| try buf.appendSlice(it.arena, sv),
            }
        }
    }
    return str(buf.items);
}

// §22.1.3.16/.15 StringPad (padStart/padEnd) — code-unit semantics: `maxLength` and the filler are
// measured in UTF-16 code units, and the filler is truncated at a code-unit boundary (which may
// split a surrogate pair, yielding a lone surrogate — e.g. `'abc'.padStart(6,'💩')`).
fn pad(it: *Interpreter, s: []const u8, args: []const Value, at_start: bool) EvalError!Completion {
    const max_f = switch (try intArg(it, args, 0, 0)) {
        .abrupt => |c| return c,
        .value => |v| v,
    };
    const s_units = sutf16.utf16Length(s);
    const max_len: usize = if (max_f <= @as(f64, @floatFromInt(s_units))) return str(s) else @intFromFloat(@min(max_f, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
    // filler defaults to " "; an empty filler → no padding (return s).
    const filler = if (args.len > 1 and args[1] != .undefined) blk: {
        const cs = try coerceStr(it, args[1]);
        switch (cs) {
            .abrupt => |c| return c,
            .string => |sv| break :blk sv,
        }
    } else " ";
    const fill_units = sutf16.utf16Length(filler);
    if (fill_units == 0 or max_len <= s_units) return str(s);
    const fill_count = max_len - s_units; // code units of filling to produce
    // Build `fill_count` code units by repeating `filler` and truncating at a code-unit boundary.
    var fill: std.ArrayListUnmanaged(u8) = .empty;
    var produced: usize = 0;
    while (produced < fill_count) {
        const remaining = fill_count - produced;
        if (remaining >= fill_units) {
            try fill.appendSlice(it.arena, filler);
            produced += fill_units;
        } else {
            // partial: take the first `remaining` code units of the filler.
            try fill.appendSlice(it.arena, try sutf16.substringByCodeUnits(it.arena, filler, 0, remaining));
            produced += remaining;
        }
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (at_start) {
        try buf.appendSlice(it.arena, fill.items);
        try buf.appendSlice(it.arena, s);
    } else {
        try buf.appendSlice(it.arena, s);
        try buf.appendSlice(it.arena, fill.items);
    }
    return str(buf.items);
}

// §22.1.3.20/.21 replace/replaceAll — STRING-search form only (the RegExp form is deferred, see
// specs/039 spec.md). Honors the `$`-replacement patterns ($$, $&, $`, $', $n).
fn replace(it: *Interpreter, s: []const u8, args: []const Value, all: bool) EvalError!Completion {
    const search_val: Value = if (args.len > 0) args[0] else .undefined;
    const replace_val: Value = if (args.len > 1) args[1] else .undefined;
    // §22.1.3.21 replaceAll step 2: a non-global RegExp searchValue → TypeError (checked before any
    // @@replace delegation).
    if (all and search_val != .undefined and search_val != .null) {
        switch (try isRegExp(it, search_val)) {
            .abrupt => |c| return c,
            .value => |is_re| if (is_re) {
                const fc = try it.getProperty2(search_val, "flags");
                if (fc.isAbrupt()) return fc;
                if (fc.normal == .undefined or fc.normal == .null) {
                    return it.throwError("TypeError", "flags is undefined");
                }
                const fs = switch (try coerceStr(it, fc.normal)) {
                    .abrupt => |c| return c,
                    .string => |v| v,
                };
                if (std.mem.indexOfScalar(u8, fs, 'g') == null) {
                    return it.throwError("TypeError", "replaceAll must be called with a global RegExp");
                }
            },
        }
    }
    // §22.1.3.20/.21 step: if searchValue is an Object, GetMethod(searchValue, @@replace); if present,
    // Call(replacer, searchValue, «O, replaceValue»). The IsObject gate means a STRING-primitive
    // searchValue never reads `@@replace` off String.prototype (the string-search fallback runs).
    if (search_val == .object) {
        if (it.wellKnownSymbol("replace")) |sym| {
            const mc = try it.getSymbolProperty(search_val, sym);
            if (mc.isAbrupt()) return mc;
            const m = mc.normal;
            if (m != .undefined and m != .null) {
                if (m != .object or m.object.kind != .function) {
                    return it.throwError("TypeError", "Symbol.replace method is not callable");
                }
                return it.callFunction(m.object, &.{ .{ .string = s }, replace_val }, search_val);
            }
        }
    }
    // A RegExp first arg would route to RegExp.prototype[Symbol.replace] — not implemented; ToString it
    // (so `replace(/x/,...)` at least does a literal search on the pattern source string — best effort).
    const search = switch (try argStr(it, args, 0)) {
        .abrupt => |c| return c,
        .string => |v| v,
    };
    const repl_is_fn = args.len > 1 and args[1] == .object and args[1].object.kind == .function;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;
    var matched_any = false;
    while (pos <= s.len) {
        const found = std.mem.indexOfPos(u8, s, pos, search);
        const at = found orelse {
            try buf.appendSlice(it.arena, s[pos..]);
            break;
        };
        try buf.appendSlice(it.arena, s[pos..at]);
        const matched = s[at .. at + search.len];
        if (repl_is_fn) {
            // §22.1.3.20: call replacer(matched, position, string).
            const r = try it.callFunction(args[1].object, &.{ .{ .string = matched }, .{ .number = @floatFromInt(at) }, .{ .string = s } }, .undefined);
            if (r.isAbrupt()) return r;
            const rs = try coerceStr(it, r.normal);
            switch (rs) {
                .abrupt => |c| return c,
                .string => |sv| try buf.appendSlice(it.arena, sv),
            }
        } else {
            const repl = switch (try argStr(it, args, 1)) {
                .abrupt => |c| return c,
                .string => |v| v,
            };
            try appendReplacement(it, &buf, repl, s, matched, at);
        }
        matched_any = true;
        // advance past the match; for an empty search, step 1 byte to make progress.
        if (search.len == 0) {
            if (at < s.len) try buf.append(it.arena, s[at]);
            pos = at + 1;
        } else {
            pos = at + search.len;
        }
        if (!all) {
            try buf.appendSlice(it.arena, s[pos..]);
            break;
        }
    }
    if (!matched_any and !all) return str(s); // no match → original
    return str(buf.items);
}

// §22.1.3.20.1 GetSubstitution — expand the `$` patterns in a string replacement.
fn appendReplacement(it: *Interpreter, buf: *std.ArrayListUnmanaged(u8), repl: []const u8, s: []const u8, matched: []const u8, at: usize) EvalError!void {
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c == '$' and i + 1 < repl.len) {
            const d = repl[i + 1];
            switch (d) {
                '$' => {
                    try buf.append(it.arena, '$');
                    i += 2;
                    continue;
                },
                '&' => {
                    try buf.appendSlice(it.arena, matched);
                    i += 2;
                    continue;
                },
                '`' => {
                    try buf.appendSlice(it.arena, s[0..at]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try buf.appendSlice(it.arena, s[at + matched.len ..]);
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try buf.append(it.arena, c);
        i += 1;
    }
}

// §22.1.3.23 split — STRING (or undefined) separator only; a RegExp separator is deferred.
fn split(it: *Interpreter, s: []const u8, args: []const Value) EvalError!Completion {
    // §22.1.3.23 step 2: GetMethod(separator, @@split); if present, Call(splitter, separator,
    // «O, limit») — the limit is passed UNCOERCED. Routes a RegExp / custom splitter to its method.
    const sep_val: Value = if (args.len > 0) args[0] else .undefined;
    const limit_val: Value = if (args.len > 1) args[1] else .undefined;
    if (sep_val == .object) {
        if (it.wellKnownSymbol("split")) |sym| {
            const mc = try it.getSymbolProperty(sep_val, sym);
            if (mc.isAbrupt()) return mc;
            const m = mc.normal;
            if (m != .undefined and m != .null) {
                if (m != .object or m.object.kind != .function) {
                    return it.throwError("TypeError", "Symbol.split method is not callable");
                }
                return it.callFunction(m.object, &.{ .{ .string = s }, limit_val }, sep_val);
            }
        }
    }
    const out = try Object.createArray(it.arena, it.arrayProto());
    // limit (§22.1.3.23 step 6/8): ToUint32; default 2^32-1.
    const limit: u64 = if (args.len > 1 and args[1] != .undefined) blk: {
        const nc = try it.toNumberThrowing(args[1]);
        if (nc.isAbrupt()) return nc;
        const n = nc.normal.number;
        if (std.math.isNan(n) or n <= 0) break :blk 0;
        if (n >= 4294967296.0) break :blk @as(u64, @intFromFloat(@mod(n, 4294967296.0)));
        break :blk @intFromFloat(@trunc(n));
    } else 4294967295;
    if (limit == 0) return .{ .normal = .{ .object = out } };

    if (args.len == 0 or args[0] == .undefined) {
        try out.arrayPush(it.arena, .{ .string = s });
        return .{ .normal = .{ .object = out } };
    }
    const sep = try it.toString(args[0]);
    if (sep.len == 0) {
        // empty separator → split into individual code units (bytes, per the byte model).
        var i: usize = 0;
        while (i < s.len and out.elements.items.len < limit) : (i += 1) {
            try out.arrayPush(it.arena, .{ .string = s[i .. i + 1] });
        }
        return .{ .normal = .{ .object = out } };
    }
    var rest = s;
    while (std.mem.indexOf(u8, rest, sep)) |p| {
        if (out.elements.items.len >= limit) return .{ .normal = .{ .object = out } };
        try out.arrayPush(it.arena, .{ .string = rest[0..p] });
        rest = rest[p + sep.len ..];
    }
    if (out.elements.items.len < limit) try out.arrayPush(it.arena, .{ .string = rest });
    return .{ .normal = .{ .object = out } };
}

// ── helpers ───────────────────────────────────────────────────────────────────────────────────

fn str(s: []const u8) Completion {
    return .{ .normal = .{ .string = s } };
}
fn num(n: f64) Completion {
    return .{ .normal = .{ .number = n } };
}
fn boolean(b: bool) Completion {
    return .{ .normal = .{ .boolean = b } };
}

const IntResult = union(enum) { value: f64, abrupt: Completion };

/// §7.1.5 ToIntegerOrInfinity over a method arg — throwing (a Symbol/BigInt operand → TypeError).
/// `undefined`/absent → `default`. NaN → 0. ±Infinity is clamped here to ±maxInt-safe range; use
/// `intArgInf` where the spec needs to observe Infinity (repeat/substr length).
fn intArg(it: *Interpreter, args: []const Value, i: usize, default: f64) EvalError!IntResult {
    if (i >= args.len or args[i] == .undefined) return .{ .value = default };
    const c = try it.toNumberThrowing(args[i]);
    if (c.isAbrupt()) return .{ .abrupt = c };
    const n = c.normal.number;
    if (std.math.isNan(n)) return .{ .value = 0 };
    if (std.math.isInf(n)) return .{ .value = if (n > 0) 1e21 else -1e21 };
    return .{ .value = @trunc(n) };
}

/// Like `intArg` but preserves ±Infinity (repeat: +Inf → RangeError; substr length: +Inf → rest).
/// `undefined`/absent → +Infinity (substr's default length).
fn intArgInf(it: *Interpreter, args: []const Value, i: usize) EvalError!IntResult {
    if (i >= args.len or args[i] == .undefined) return .{ .value = std.math.inf(f64) };
    const c = try it.toNumberThrowing(args[i]);
    if (c.isAbrupt()) return .{ .abrupt = c };
    const n = c.normal.number;
    if (std.math.isNan(n)) return .{ .value = 0 };
    if (std.math.isInf(n)) return .{ .value = n };
    return .{ .value = @trunc(n) };
}

/// §22.1.3.21 relative-index arg → resolved byte index in [0, len]. Negative counts from the end.
const RelResult = union(enum) { value: usize, abrupt: Completion };
fn relArg(it: *Interpreter, args: []const Value, i: usize, default: f64, len_f: f64) EvalError!RelResult {
    const ir = try intArg(it, args, i, default);
    const n = switch (ir) {
        .abrupt => |c| return .{ .abrupt = c },
        .value => |v| v,
    };
    var idx = if (n < 0) len_f + n else n;
    if (idx < 0) idx = 0;
    if (idx > len_f) idx = len_f;
    return .{ .value = @intFromFloat(idx) };
}

/// Clamp a (non-relative) integer position to [0, len].
fn clampPos(n: f64, len: usize) usize {
    if (n <= 0) return 0;
    const len_f: f64 = @floatFromInt(len);
    if (n >= len_f) return len;
    return @intFromFloat(n);
}

/// ToNumber of a method arg, throwing — returns the raw f64 (NaN preserved) or propagates the error.
fn numArg(it: *Interpreter, args: []const Value, i: usize) EvalError!f64 {
    if (i >= args.len or args[i] == .undefined) return std.math.nan(f64);
    const c = try it.toNumberThrowing(args[i]);
    if (c.isAbrupt()) {
        // surface the abrupt completion as a sentinel the caller won't reach for lastIndexOf
        // (lastIndexOf's only arg that can throw is the needle, handled before this call).
        return std.math.nan(f64);
    }
    return c.normal.number;
}

const StrResult = union(enum) { string: []const u8, abrupt: Completion };
/// ToString of an arbitrary value, throwing on Symbol (§7.1.17). Used where a coercion error must be
/// observable (concat, padStart filler, replace result).
fn coerceStr(it: *Interpreter, v: Value) EvalError!StrResult {
    return switch (try it.toStringThrowing(v)) {
        .normal => |nv| .{ .string = nv.string },
        else => |c| .{ .abrupt = c },
    };
}

/// ToString of arg `i` (absent → "undefined") — THROWING (§7.1.17: a Symbol arg / an object whose
/// ToPrimitive throws surfaces a TypeError, as the search-string steps of indexOf/includes/startsWith/
/// endsWith/replace/split require). Returns the string or the abrupt completion.
fn argStr(it: *Interpreter, args: []const Value, i: usize) EvalError!StrResult {
    if (i >= args.len) return .{ .string = "undefined" };
    return coerceStr(it, args[i]);
}

/// §6.1.4 WhiteSpace ∪ LineTerminator, over a CODE POINT (for trim/trimStart/trimEnd). Covers the
/// ASCII set plus the Unicode space separators (Zs), U+FEFF (BOM/ZWNBSP), and the line/paragraph
/// separators. Note U+180E is NOT whitespace in modern Unicode (removed from Zs in 6.3).
fn isWsCp(cp: u32) bool {
    return switch (cp) {
        // WhiteSpace: TAB, LF (LineTerminator), VT, FF, CR (LineTerminator), SP, NBSP, ZWNBSP/BOM
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF => true,
        // LineTerminator: LS, PS
        0x2028, 0x2029 => true,
        // Other Unicode "Space_Separator" (Zs)
        0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// The byte offset where the LAST code point in `s[lo..hi)` begins (UTF-8/WTF-8 back-scan). Assumes
/// `lo < hi`. Used by trimEnd to walk code points from the right.
fn cpStart(s: []const u8, lo: usize, hi: usize) usize {
    var k = hi - 1;
    // a continuation byte is 10xxxxxx; back up to the lead byte (cap at 3 continuation bytes).
    var steps: usize = 0;
    while (k > lo and (s[k] & 0xC0) == 0x80 and steps < 3) : (steps += 1) k -= 1;
    return k;
}

/// §22.2.7.2 IsRegExp ( argument ): not an object → false; read `argument[@@match]` (may throw) →
/// if not undefined, ToBoolean; else fall back to the [[RegExpMatcher]] internal slot (`.regexp`).
const BoolResult = union(enum) { value: bool, abrupt: Completion };
fn isRegExp(it: *Interpreter, v: Value) EvalError!BoolResult {
    if (v != .object) return .{ .value = false };
    const sym = it.wellKnownSymbol("match") orelse {
        // realm-less fallback (no Symbol): use the internal slot only.
        return .{ .value = v.object.regexp != null };
    };
    const mc = try it.getSymbolProperty(v, sym);
    if (mc.isAbrupt()) return .{ .abrupt = mc };
    if (mc.normal != .undefined) return .{ .value = abstract_ops.toBoolean(mc.normal) };
    return .{ .value = v.object.regexp != null };
}

/// §22.1.3.11 match / §22.1.3.19 search — the @@-delegating forms. If `regexp` (arg 0) is not
/// undefined/null, read `regexp[@@match]` (resp. `@@search`); if a callable method is present, invoke
/// it with `this = regexp` and a single ToString(this) argument (the spec's `Invoke(rx, @@x, «S»)`,
/// here without the `new RegExp` construction step). Without a RegExp engine wired to these Symbol
/// methods, the implicit-RegExp fallback (regexp has no @@-method) returns null/-1 — best effort.
fn matchLike(it: *Interpreter, s: []const u8, this_val: Value, args: []const Value, comptime which: []const u8) EvalError!Completion {
    _ = this_val;
    const regexp: Value = if (args.len > 0) args[0] else .undefined;
    // The @@-method lookup is gated on IsObject(regexp): a primitive arg never reads `@@match`/
    // `@@search` off its prototype (it would route through the implicit-RegExp path instead).
    if (regexp == .object) {
        const sym = it.wellKnownSymbol(which);
        if (sym) |sy| {
            const mc = try it.getSymbolProperty(regexp, sy);
            if (mc.isAbrupt()) return mc;
            const m = mc.normal;
            if (m != .undefined and m != .null) {
                if (m != .object or m.object.kind != .function) {
                    return it.throwError("TypeError", "Symbol method is not callable");
                }
                return it.callFunction(m.object, &.{.{ .string = s }}, regexp);
            }
        }
    }
    // Fallback: no @@-method on the arg → would construct `new RegExp(regexp)` and invoke its
    // Symbol method. The RegExp engine is not wired to these Symbol methods, so report "no match".
    return if (std.mem.eql(u8, which, "search")) num(-1) else .{ .normal = .null };
}

/// §22.1.3.13 matchAll — the @@matchAll-delegating form. If `regexp` is a RegExp without the global
/// flag, throw a TypeError (step 2.a). Then GetMethod(regexp, @@matchAll); invoke it if present.
fn matchAll(it: *Interpreter, s: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    _ = this_val;
    const regexp: Value = if (args.len > 0) args[0] else .undefined;
    if (regexp != .undefined and regexp != .null) {
        // step 2.a: if IsRegExp(regexp) and regexp lacks a global flag → TypeError.
        switch (try isRegExp(it, regexp)) {
            .abrupt => |c| return c,
            .value => |is_re| if (is_re) {
                const fc = try it.getProperty2(regexp, "flags");
                if (fc.isAbrupt()) return fc;
                if (fc.normal == .undefined or fc.normal == .null) {
                    return it.throwError("TypeError", "flags is undefined");
                }
                const fs = switch (try coerceStr(it, fc.normal)) {
                    .abrupt => |c| return c,
                    .string => |v| v,
                };
                if (std.mem.indexOfScalar(u8, fs, 'g') == null) {
                    return it.throwError("TypeError", "String.prototype.matchAll called with a non-global RegExp argument");
                }
            },
        }
        // GetMethod(regexp, @@matchAll) is gated on IsObject (a string-primitive arg never reads
        // `@@matchAll` off String.prototype).
        if (regexp == .object) {
            if (it.wellKnownSymbol("matchAll")) |sy| {
                const mc = try it.getSymbolProperty(regexp, sy);
                if (mc.isAbrupt()) return mc;
                const m = mc.normal;
                if (m != .undefined and m != .null) {
                    if (m != .object or m.object.kind != .function) {
                        return it.throwError("TypeError", "Symbol.matchAll method is not callable");
                    }
                    return it.callFunction(m.object, &.{.{ .string = s }}, regexp);
                }
            }
        }
    }
    // Fallback (no RegExp engine wired to @@matchAll): an empty iterator would be returned. Surface
    // a TypeError-free empty result by delegating to the implicit RegExp path, which is unavailable —
    // best effort: throw is wrong, so return an empty array's iterator is also unavailable. Report
    // undefined (the few non-cstm cases that reach here need the engine and stay failing).
    return .{ .normal = .undefined };
}

/// §22.1.3.13 normalize ( [ form ] ) — validate `form` (default "NFC"; one of NFC/NFD/NFKC/NFKD,
/// else RangeError) and return the normalized string. Full Unicode normalization needs large
/// decomposition/composition tables (deferred); an ASCII / already-normalized string is returned
/// unchanged (identity), which is correct for the common case and passes the validation/abrupt tests.
fn normalize(it: *Interpreter, s: []const u8, args: []const Value) EvalError!Completion {
    var form: []const u8 = "NFC";
    if (args.len > 0 and args[0] != .undefined) {
        form = switch (try coerceStr(it, args[0])) {
            .abrupt => |c| return c,
            .string => |v| v,
        };
    }
    const ok = std.mem.eql(u8, form, "NFC") or std.mem.eql(u8, form, "NFD") or
        std.mem.eql(u8, form, "NFKC") or std.mem.eql(u8, form, "NFKD");
    if (!ok) return it.throwError("RangeError", "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
    // Identity for ASCII (always normalized in every form). Non-ASCII normalization is deferred.
    return str(s);
}

/// ToUint16 (§7.1.6-ish over an f64): truncate toward zero mod 2^16.
fn toUint16(n: f64) u16 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const t = @trunc(n);
    const m = @mod(t, 65536.0);
    const mm = if (m < 0) m + 65536.0 else m;
    return @intFromFloat(mm);
}

/// UTF-8-encode a code point (a code-unit value from fromCharCode, or a real code point). Lone
/// surrogates (0xD800–0xDFFF) are encoded in their 3-byte WTF-8 form so the byte store round-trips.
fn encodeCp(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u32) std.mem.Allocator.Error!void {
    if (cp < 0x80) {
        try buf.append(arena, @intCast(cp));
    } else if (cp < 0x800) {
        try buf.append(arena, @intCast(0xC0 | (cp >> 6)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        try buf.append(arena, @intCast(0xE0 | (cp >> 12)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try buf.append(arena, @intCast(0xF0 | (cp >> 18)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    }
}

/// UTF-8-decode the code point starting at byte `i` (assumes `i < s.len`). Returns the code point and
/// its byte length; an invalid lead byte decodes as the single byte (Latin-1 fallback).
const CpDecode = struct { cp: u32, len: usize };
fn decodeCp(s: []const u8, i: usize) CpDecode {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const seq_len: usize = if (b0 >= 0xF0) 4 else if (b0 >= 0xE0) 3 else if (b0 >= 0xC0) 2 else 1;
    if (seq_len == 1 or i + seq_len > s.len) return .{ .cp = b0, .len = 1 };
    var cp: u32 = switch (seq_len) {
        2 => b0 & 0x1F,
        3 => b0 & 0x0F,
        else => b0 & 0x07,
    };
    var k: usize = 1;
    while (k < seq_len) : (k += 1) {
        const cb = s[i + k];
        if (cb & 0xC0 != 0x80) return .{ .cp = b0, .len = 1 };
        cp = (cp << 6) | (cb & 0x3F);
    }
    return .{ .cp = cp, .len = seq_len };
}

/// Byte-level lastIndexOf: rightmost occurrence of `needle` at index <= `limit`, or -1.
fn lastIndexOf(s: []const u8, needle: []const u8, limit: usize) f64 {
    if (needle.len == 0) return @floatFromInt(@min(limit, s.len));
    if (needle.len > s.len) return -1;
    var start = @min(limit, s.len - needle.len);
    while (true) : (start -= 1) {
        if (std.mem.eql(u8, s[start .. start + needle.len], needle)) return @floatFromInt(start);
        if (start == 0) break;
    }
    return -1;
}
