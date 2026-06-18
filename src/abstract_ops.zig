//! ECMA-262 abstract operations — type conversion (§7.1), comparison (§7.2), plus the `typeof`
//! and `instanceof` operator helpers. Pure functions over `Value` (no interpreter state);
//! `toString`/`numberToString` take an arena for string building. Extracted from the interpreter
//! so the evaluator stays focused and these stay 1:1 with their spec clauses.
const std = @import("std");
const Value = @import("value.zig").Value;
const bigint = @import("bigint.zig");

/// §7.1.4 ToNumber (subset; primitives only).
pub fn toNumber(v: Value) f64 {
    return switch (v) {
        .number => |n| n,
        .undefined => std.math.nan(f64),
        .null => 0,
        .boolean => |b| if (b) 1 else 0,
        .string => |s| stringToNumber(s),
        .symbol => std.math.nan(f64), // §7.1.4: ToNumber(Symbol) throws — surfaced as NaN here (caller checks)
        .bigint => std.math.nan(f64), // §7.1.4: ToNumber(BigInt) throws — surfaced as NaN (caller checks tag)
        .object => std.math.nan(f64), // ToPrimitive deferred → NaN
    };
}

/// True if the WTF-8 byte run starting at `s[i]` is a §12.2 StrWhiteSpace code point (the white-space
/// + line-terminator set ToNumber trims from a numeric string). Sets `len` to the code point's byte
/// width. Covers the ASCII set plus the multibyte ones Test262 exercises (NBSP, the Unicode space
/// separators U+2000..U+200A / U+202F / U+205F / U+3000, LS/PS U+2028/U+2029, BOM U+FEFF).
fn strWhiteSpaceAt(s: []const u8, i: usize, len: *usize) bool {
    const c = s[i];
    if (c < 0x80) {
        len.* = 1;
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
    }
    // Decode just enough to recognise the multibyte white-space code points.
    if (c == 0xC2 and i + 1 < s.len and s[i + 1] == 0xA0) { // U+00A0 NBSP
        len.* = 2;
        return true;
    }
    if (c == 0xE1 and i + 2 < s.len and s[i + 1] == 0x9A and s[i + 2] == 0x80) { // U+1680 OGHAM SPACE MARK
        len.* = 3;
        return true;
    }
    if (c == 0xE2 and i + 2 < s.len) {
        const cp = (@as(u21, c & 0x0F) << 12) | (@as(u21, s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
        // U+2000..U+200A, U+2028 (LS), U+2029 (PS), U+202F (NNBSP), U+205F (MMSP).
        if ((cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F) {
            len.* = 3;
            return true;
        }
    }
    if (c == 0xE3 and i + 2 < s.len and s[i + 1] == 0x80 and s[i + 2] == 0x80) { // U+3000 IDEOGRAPHIC SPACE
        len.* = 3;
        return true;
    }
    if (c == 0xEF and i + 2 < s.len and s[i + 1] == 0xBB and s[i + 2] == 0xBF) { // U+FEFF BOM / ZWNBSP
        len.* = 3;
        return true;
    }
    len.* = 1;
    return false;
}

/// §7.1.4.1.1 StringToNumber — parse a string per the StrNumericLiteral grammar (NOT
/// `std.fmt.parseFloat`, which accepts `_` separators and other non-ECMAScript forms). Trims
/// §12.2 StrWhiteSpace from both ends; empty (or all-white-space) → +0; `Infinity`/`±Infinity`;
/// the `0x`/`0o`/`0b` radix integer literals (no sign); otherwise a decimal StrDecimalLiteral
/// (optional sign, integer/fraction, optional exponent) with NO numeric-separator `_`. Anything
/// the grammar rejects → NaN.
pub fn stringToNumber(s: []const u8) f64 {
    // Trim leading/trailing StrWhiteSpace.
    var start: usize = 0;
    while (start < s.len) {
        var w: usize = 1;
        if (!strWhiteSpaceAt(s, start, &w)) break;
        start += w;
    }
    var end: usize = s.len;
    while (end > start) {
        // Find the start of the last code point in [start, end) and test it.
        var j = end - 1;
        while (j > start and (s[j] & 0xC0) == 0x80) j -= 1;
        var w: usize = 1;
        if (!strWhiteSpaceAt(s, j, &w) or j + w != end) break;
        end = j;
    }
    const t = s[start..end];
    if (t.len == 0) return 0; // StrWhiteSpace-only → +0

    // Infinity / ±Infinity.
    if (std.mem.eql(u8, t, "Infinity") or std.mem.eql(u8, t, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, t, "-Infinity")) return -std.math.inf(f64);

    // Radix integer literals: 0x/0X (hex), 0o/0O (octal), 0b/0B (binary). No sign permitted.
    if (t.len > 2 and t[0] == '0') {
        const radix: ?u8 = switch (t[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| return radixDigitsToNumber(t[2..], r);
    }

    // Decimal StrDecimalLiteral — reject anything `std.fmt.parseFloat` would over-accept
    // (numeric separators, hex floats, etc.).
    if (!isStrDecimalLiteral(t)) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
}

/// Parse `digits` as a non-empty run of base-`radix` digits → its Number value (used for the
/// `0x`/`0o`/`0b` StringToNumber prefixes). Empty or any out-of-range digit → NaN. Accumulates in
/// f64 so very long literals round to the nearest Number (matching the spec's MV → Number rounding).
fn radixDigitsToNumber(digits: []const u8, radix: u8) f64 {
    if (digits.len == 0) return std.math.nan(f64);
    var acc: f64 = 0;
    const rf: f64 = @floatFromInt(radix);
    for (digits) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            else => return std.math.nan(f64),
        };
        if (d >= radix) return std.math.nan(f64);
        acc = acc * rf + @as(f64, @floatFromInt(d));
    }
    return acc;
}

/// True if `t` matches the §12.9.3 StrDecimalLiteral grammar: optional sign, then `.`-fraction or
/// integer[.fraction], with an optional `e`/`E` signed exponent; ASCII digits only, NO `_`
/// separators, NO hex/inf forms (those are handled by the caller). At least one digit is required.
fn isStrDecimalLiteral(t: []const u8) bool {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    var saw_digit = false;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_digit = true;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return false; // need at least one digit before/after the dot
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        var saw_exp = false;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_exp = true;
        if (!saw_exp) return false; // exponent indicator with no digits
    }
    return i == t.len; // every byte consumed → valid; trailing junk (e.g. "_", "0x") → invalid
}

/// §7.1.2 ToBoolean.
pub fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
        .bigint => |b| !bigint.isZero(b), // §7.1.2: 0n → false, every other BigInt → true
        .symbol => true, // §7.1.2: a Symbol is always truthy
        .object => true,
    };
}

/// §7.1.17 ToString (handles Array → join(",") ; other objects → "[object Object]").
pub fn toString(arena: std.mem.Allocator, v: Value) error{OutOfMemory}![]const u8 {
    return switch (v) {
        .string => |s| s,
        .undefined => "undefined",
        .null => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| numberToString(arena, n),
        // §6.1.6.2.23 BigInt::toString — decimal digits, leading '-' for negatives.
        .bigint => |b| bigint.toStringRadix(arena, b, 10) catch return error.OutOfMemory,
        // §7.1.17 ToString(Symbol) throws a TypeError; that throw is raised by the interpreter's
        // `toString` wrapper before reaching here. This descriptive form is only a fallback for the
        // ALLOWED conversions (`String(sym)` / `sym.toString()`), which route here deliberately.
        .symbol => |s| if (s.description) |d|
            try std.fmt.allocPrint(arena, "Symbol({s})", .{d})
        else
            "Symbol()",
        .object => |o| blk: {
            if (o.kind != .array) break :blk "[object Object]"; // §20.1.3.6 (ToPrimitive deferred)
            var buf: std.ArrayList(u8) = .empty;
            const len = o.arrayLen(); // §23.1.3.17: holes/undefined/null → empty between separators
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (i > 0) try buf.appendSlice(arena, ",");
                const el = o.arrayGet(i);
                if (el != .undefined and el != .null) try buf.appendSlice(arena, try toString(arena, el));
            }
            break :blk buf.items;
        },
    };
}

/// §6.1.6.1.21 Number::toString (subset).
pub fn numberToString(arena: std.mem.Allocator, n: f64) error{OutOfMemory}![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isPositiveInf(n)) return "Infinity";
    if (std.math.isNegativeInf(n)) return "-Infinity";
    if (n == 0) return "0"; // §6.1.6.1.20: both +0 and -0 → "0"
    const a = @abs(n);
    // §6.1.6.1.20 steps 8–9: a magnitude ≥ 1e21 (decimal exponent of the leading digit ≥ 21) or
    // < 1e-6 (≤ -7) renders in EXPONENTIAL form ("1e+21", "1e-7") — exactly where Zig's `{d}` fixed
    // formatting diverges from the spec. The non-exponential range below is left to `{d}` (shortest
    // fixed), which already matches the spec, so common-case stringification is byte-for-byte unchanged.
    if (a >= 1e21 or a < 1e-6) return ecmaExponential(arena, n);
    // Integral values that fit in i64 format cleanly as an integer (no exponent). Numbers in
    // [2^63, 1e21) are still integral per `@floor` but exceed i64 → `@intFromFloat` would panic, so
    // fall through to float formatting (which renders them without a spurious decimal point).
    if (n == @floor(n) and a < 9.2e18) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// §6.1.6.1.20 exponential rendering (`s[.ddd]e±E`): take Zig's shortest scientific form, extract the
/// significand digits (trailing zeros trimmed) and the leading-digit exponent E, then format per spec —
/// `d` or `d.ddd`, then `e`, the sign, and |E|. Only invoked for magnitudes that the spec renders
/// exponentially, so the leading digit is always present and nonzero.
fn ecmaExponential(arena: std.mem.Allocator, n: f64) error{OutOfMemory}![]const u8 {
    const sci = try std.fmt.allocPrint(arena, "{e}", .{@abs(n)});
    const e_idx = std.mem.indexOfScalar(u8, sci, 'e') orelse return sci; // defensive; always present
    const mant = sci[0..e_idx];
    const e_val = std.fmt.parseInt(i64, sci[e_idx + 1 ..], 10) catch 0;
    // Significand digits with the '.' removed, then trailing zeros trimmed (keep ≥ 1) → canonical `s`.
    var digbuf = try arena.alloc(u8, mant.len);
    var k: usize = 0;
    for (mant) |c| {
        if (c != '.') {
            digbuf[k] = c;
            k += 1;
        }
    }
    while (k > 1 and digbuf[k - 1] == '0') k -= 1;
    const digits = digbuf[0..k];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (n < 0) try out.append(arena, '-');
    if (k == 1) {
        try out.append(arena, digits[0]);
    } else {
        try out.append(arena, digits[0]);
        try out.append(arena, '.');
        try out.appendSlice(arena, digits[1..]);
    }
    try out.append(arena, 'e');
    try out.append(arena, if (e_val >= 0) '+' else '-');
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{@abs(e_val)}));
    return out.items;
}

/// §7.1.6 ToInt32 from an already-computed Number — truncate, modulo 2^32, interpret as signed.
pub fn numberToInt32(n: f64) i32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const two32 = 4294967296.0;
    const m = @mod(std.math.trunc(n), two32); // [0, 2^32)
    const u: u32 = @intFromFloat(m);
    return @bitCast(u);
}

/// §7.1.7 ToUint32 from an already-computed Number.
pub fn numberToUint32(n: f64) u32 {
    return @bitCast(numberToInt32(n));
}

/// §7.1.6 ToInt32 — ToNumber, truncate, modulo 2^32, interpret as signed.
pub fn toInt32(v: Value) i32 {
    return numberToInt32(toNumber(v));
}

/// §7.1.7 ToUint32.
pub fn toUint32(v: Value) u32 {
    return @bitCast(toInt32(v));
}

/// §13.5.3 The typeof Operator.
pub fn typeOf(v: Value) []const u8 {
    return switch (v) {
        .undefined => "undefined",
        .null => "object", // the historical quirk
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .bigint => "bigint", // §13.5.3
        .symbol => "symbol", // §13.5.3
        .object => |o| if (o.kind == .function) "function" else "object",
    };
}

pub const RelOp = enum { lt, gt, le, ge };

fn applyOrder(order: std.math.Order, op: RelOp) bool {
    return switch (op) {
        .lt => order == .lt,
        .gt => order == .gt,
        .le => order != .gt,
        .ge => order != .lt,
    };
}

/// §7.2.13 / §13.10 Relational comparison. Operands are already primitives (ToPrimitive done by the
/// caller's `relationalV`). BigInt compares numerically against BigInt / Number / numeric String.
pub fn relational(l: Value, r: Value, op: RelOp) bool {
    if (l == .string and r == .string) {
        return applyOrder(std.mem.order(u8, l.string, r.string), op);
    }
    // §7.2.13: any BigInt operand makes the comparison a numeric (mathematical) ordering.
    if (l == .bigint or r == .bigint) {
        const o = bigintRelOrder(l, r) orelse return false; // NaN-involved → false
        return applyOrder(o, op);
    }
    const a = toNumber(l);
    const b = toNumber(r);
    if (std.math.isNan(a) or std.math.isNan(b)) return false;
    return switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
}

/// §7.2.13 the mathematical ordering of `l` ? `r` when at least one is a BigInt. Returns null when a
/// numeric operand is NaN (an unordered comparison → always false). A String operand is parsed as a
/// Number (StringToNumber); a Boolean/etc. is ToNumber'd. BigInt↔BigInt is exact; BigInt↔Number
/// compares the BigInt's value (via f64; exact for integral Numbers, ±Inf saturation is correct).
fn bigintRelOrder(l: Value, r: Value) ?std.math.Order {
    if (l == .bigint and r == .bigint) return bigint.order(l.bigint, r.bigint);
    if (l == .bigint) {
        const rn = if (r == .string) strToNumber(r.string) else toNumber(r);
        if (std.math.isNan(rn)) return null;
        return std.math.order(bigint.toF64(l.bigint), rn);
    }
    // r is bigint, l is not
    const ln = if (l == .string) strToNumber(l.string) else toNumber(l);
    if (std.math.isNan(ln)) return null;
    return std.math.order(ln, bigint.toF64(r.bigint));
}

fn strToNumber(s: []const u8) f64 {
    return stringToNumber(s); // §7.1.4.1.1 StrNumericLiteral (rejects `_`, honors 0x/0o/0b)
}

/// §7.2.16 IsStrictlyEqual (===).
pub fn strictEquals(l: Value, r: Value) bool {
    return switch (l) {
        .undefined => r == .undefined,
        .null => r == .null,
        .boolean => |b| r == .boolean and r.boolean == b,
        .number => |n| r == .number and r.number == n,
        .string => |s| r == .string and std.mem.eql(u8, s, r.string),
        // §7.2.16: BigInt === only another BigInt with the same numeric value (so `1n === 1` is false).
        .bigint => |b| r == .bigint and bigint.eql(b, r.bigint),
        .symbol => |s| r == .symbol and r.symbol == s, // §6.1.5: Symbols are equal iff the same identity
        .object => |o| r == .object and r.object == o, // reference equality
    };
}

/// §7.2.11 SameValue ( x, y ) — like `===` except NaN equals NaN and +0 is distinct from -0
/// (the equality used by `Object.is`, §20.1.2.14, and the §10.1.6.3 redefinition invariant).
pub fn sameValue(x: Value, y: Value) bool {
    if (x == .number and y == .number) {
        const a = x.number;
        const b = y.number;
        if (std.math.isNan(a) and std.math.isNan(b)) return true; // §6.1.6.1.14: NaN is SameValue NaN
        if (a == 0 and b == 0) return std.math.signbit(a) == std.math.signbit(b); // +0 ≠ -0
        return a == b;
    }
    return strictEquals(x, y);
}

/// §7.2.12 SameValueZero ( x, y ) — like SameValue except +0 and -0 compare equal (NaN still equals
/// NaN). Used by Array.prototype.includes (§23.1.3.16) and the Map/Set key model.
pub fn sameValueZero(x: Value, y: Value) bool {
    if (x == .number and y == .number) {
        const a = x.number;
        const b = y.number;
        if (std.math.isNan(a) and std.math.isNan(b)) return true; // NaN is SameValueZero NaN
        return a == b; // +0 == -0 here (unlike SameValue)
    }
    return strictEquals(x, y);
}

/// §7.2.15 IsLooselyEqual (==) — primitive subset.
pub fn looseEquals(l: Value, r: Value) bool {
    if (@as(std.meta.Tag(Value), l) == @as(std.meta.Tag(Value), r)) return strictEquals(l, r);
    if ((l == .null and r == .undefined) or (l == .undefined and r == .null)) return true;
    if (l == .undefined or l == .null or r == .undefined or r == .null) return false;
    // §7.2.15 steps 6–10: BigInt ↔ Number/String/Boolean compares numerically (cross-type). A Symbol
    // is never == a BigInt. (BigInt ↔ BigInt took the tag-equal fast path above.)
    if (l == .bigint or r == .bigint) {
        if (l == .symbol or r == .symbol) return false;
        return bigintLooseEqual(l, r);
    }
    return toNumber(l) == toNumber(r);
}

/// §7.2.15 a BigInt loosely equals a Number iff it equals the Number mathematically (so `1n == 1`,
/// `1n == 1.0`, but not `1n == 1.5`); against a String, the String is parsed as a BigInt (an invalid
/// numeric string → not equal); a Boolean is ToNumber'd first. Exactly one operand is a BigInt here.
fn bigintLooseEqual(l: Value, r: Value) bool {
    const b = if (l == .bigint) l.bigint else r.bigint;
    const other = if (l == .bigint) r else l;
    switch (other) {
        .boolean => |bo| return std.math.order(bigint.toF64(b), if (bo) @as(f64, 1) else 0) == .eq,
        .number => |n| {
            if (std.math.isNan(n) or std.math.isInf(n)) return false;
            if (@floor(n) != n) return false; // a non-integer Number is never == a BigInt
            return std.math.order(bigint.toF64(b), n) == .eq;
        },
        .string => |s| {
            // §7.2.15: let `o` = StringToBigInt(s); if `o` is undefined return false; else b == o.
            // We approximate via f64 ordering (exact for the integral magnitudes Test262 uses).
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len == 0) return bigint.isZero(b);
            const n = std.fmt.parseFloat(f64, t) catch return false;
            if (@floor(n) != n or std.math.isInf(n)) return false;
            return std.math.order(bigint.toF64(b), n) == .eq;
        },
        else => return false,
    }
}

/// §13.10.2 InstanceofOperator (M1: ordinary prototype-chain check; lenient on non-callable RHS).
pub fn instanceOf(l: Value, r: Value) bool {
    if (r != .object or r.object.kind != .function) return false;
    const pv = r.object.get("prototype") orelse return false;
    if (pv != .object) return false;
    const target = pv.object;
    if (l != .object) return false;
    var p = l.object.prototype;
    while (p) |proto| {
        if (proto == target) return true;
        p = proto.prototype;
    }
    return false;
}

/// Canonical array-index string ("0".."N") → usize, else null.
pub fn parseIndex(key: []const u8) ?usize {
    if (key.len == 0) return null;
    for (key) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, key, 10) catch null;
}
