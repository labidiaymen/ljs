//! §6.1.4 UTF-16 string views over the engine's WTF-8 `[]const u8` storage. ljs stores strings as
//! bytes (UTF-8, generalized to WTF-8 so lone surrogates U+D800..U+DFFF are representable as their
//! 3-byte encoding). These helpers compute the OBSERVABLE UTF-16 code-unit quantities (`length`,
//! indexing, `charCodeAt`, `charAt`) on demand. An ASCII fast path keeps all-ASCII strings (the vast
//! majority) byte-identical to direct indexing. Astral scalars (cp ≥ 0x10000) count as 2 code units
//! and decompose into a surrogate pair on access. Phase 1 of the `specs/068-utf16-strings/` epic.
const std = @import("std");

/// True iff `s` contains no byte ≥ 0x80 — then code-unit length == byte length and code-unit index
/// == byte index (the O(1) fast path). NOTE: O(n) scan; a future phase may cache this on the string.
pub fn isAscii(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

const Decoded = struct { cp: u21, len: usize };

/// Lenient WTF-8 decode of the sequence at `s[i]`: like UTF-8 but ACCEPTS the 3-byte encodings of
/// surrogates (D800..DFFF) that strict UTF-8 rejects. A malformed lead/continuation consumes a
/// single byte as U+FFFD so callers always make progress.
fn decodeAt(s: []const u8, i: usize) Decoded {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 >= 0xC2 and b0 <= 0xDF and i + 1 < s.len) {
        const b1 = s[i + 1];
        if (b1 & 0xC0 == 0x80) return .{ .cp = (@as(u21, b0 & 0x1F) << 6) | (b1 & 0x3F), .len = 2 };
    }
    if (b0 >= 0xE0 and b0 <= 0xEF and i + 2 < s.len) {
        const b1 = s[i + 1];
        const b2 = s[i + 2];
        if (b1 & 0xC0 == 0x80 and b2 & 0xC0 == 0x80) {
            const cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F);
            return .{ .cp = cp, .len = 3 }; // includes surrogates (WTF-8)
        }
    }
    if (b0 >= 0xF0 and b0 <= 0xF4 and i + 3 < s.len) {
        const b1 = s[i + 1];
        const b2 = s[i + 2];
        const b3 = s[i + 3];
        if (b1 & 0xC0 == 0x80 and b2 & 0xC0 == 0x80 and b3 & 0xC0 == 0x80) {
            const cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) |
                (@as(u21, b2 & 0x3F) << 6) | (b3 & 0x3F);
            return .{ .cp = cp, .len = 4 };
        }
    }
    return .{ .cp = 0xFFFD, .len = 1 }; // malformed — one byte
}

/// §6.1.4: the number of UTF-16 code units in `s` (astral scalar = 2).
pub fn utf16Length(s: []const u8) usize {
    if (isAscii(s)) return s.len;
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        n += if (d.cp >= 0x10000) @as(usize, 2) else 1;
        i += d.len;
    }
    return n;
}

/// The UTF-16 code unit at code-unit index `idx` (decomposing an astral scalar into its surrogate
/// pair), or null if out of range. ASCII fast path: `s[idx]`.
pub fn codeUnitAt(s: []const u8, idx: usize) ?u16 {
    if (isAscii(s)) return if (idx < s.len) s[idx] else null;
    var i: usize = 0;
    var cu: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (d.cp >= 0x10000) {
            const c: u21 = d.cp - 0x10000;
            if (cu == idx) return @intCast(0xD800 + (c >> 10));
            if (cu + 1 == idx) return @intCast(0xDC00 + (c & 0x3FF));
            cu += 2;
        } else {
            if (cu == idx) return @intCast(d.cp);
            cu += 1;
        }
        i += d.len;
    }
    return null;
}

/// Encode a single UTF-16 code unit as WTF-8 into `buf` (≤ 3 bytes); returns the written slice.
/// A surrogate (0xD800..0xDFFF) yields its 3-byte WTF-8 form.
pub fn codeUnitToWtf8(unit: u16, buf: *[3]u8) []const u8 {
    if (unit < 0x80) {
        buf[0] = @intCast(unit);
        return buf[0..1];
    }
    if (unit < 0x800) {
        buf[0] = @intCast(0xC0 | (unit >> 6));
        buf[1] = @intCast(0x80 | (unit & 0x3F));
        return buf[0..2];
    }
    buf[0] = @intCast(0xE0 | (unit >> 12));
    buf[1] = @intCast(0x80 | ((unit >> 6) & 0x3F));
    buf[2] = @intCast(0x80 | (unit & 0x3F));
    return buf[0..3];
}

/// The single-code-unit substring at code-unit index `idx` (the `String.prototype.charAt` / `[i]`
/// value), allocated in `arena`; empty string when out of range. ASCII fast path slices one byte.
pub fn charAtAlloc(arena: std.mem.Allocator, s: []const u8, idx: usize) std.mem.Allocator.Error![]const u8 {
    const unit = codeUnitAt(s, idx) orelse return "";
    var buf: [3]u8 = undefined;
    const enc = codeUnitToWtf8(unit, &buf);
    return arena.dupe(u8, enc);
}

/// The byte offset of UTF-16 code-unit index `cu`, clamped to `s.len`. If `cu` falls on the LOW
/// half of an astral pair (mid-character), returns the byte offset of that astral char's start
/// (callers that need exact mid-pair slicing use `substringByCodeUnits`). ASCII fast path: min(cu,len).
pub fn byteIndex(s: []const u8, cu: usize) usize {
    if (isAscii(s)) return @min(cu, s.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        if (n >= cu) return i;
        const d = decodeAt(s, i);
        n += if (d.cp >= 0x10000) @as(usize, 2) else 1;
        i += d.len;
    }
    return s.len;
}

/// The UTF-16 code-unit index at byte offset `byte` (number of code units fully before it). ASCII
/// fast path: `byte`. Used to convert a byte-search result back to a code-unit position.
pub fn codeUnitIndex(s: []const u8, byte: usize) usize {
    if (isAscii(s)) return byte;
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and i < byte) {
        const d = decodeAt(s, i);
        n += if (d.cp >= 0x10000) @as(usize, 2) else 1;
        i += d.len;
    }
    return n;
}

/// The substring of `s` spanning code-unit indices [a, b) (a ≤ b assumed; clamped to length),
/// allocated in `arena`. Iterates code units and re-encodes (so a boundary falling MID-astral
/// correctly yields a lone surrogate). ASCII fast path slices the bytes directly.
pub fn substringByCodeUnits(arena: std.mem.Allocator, s: []const u8, a: usize, b: usize) std.mem.Allocator.Error![]const u8 {
    if (isAscii(s)) {
        const lo = @min(a, s.len);
        const hi = @min(b, s.len);
        return if (lo >= hi) "" else s[lo..hi];
    }
    if (a >= b) return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var cu: usize = a;
    while (cu < b) : (cu += 1) {
        const unit = codeUnitAt(s, cu) orelse break;
        var buf: [3]u8 = undefined;
        try out.appendSlice(arena, codeUnitToWtf8(unit, &buf));
    }
    // A boundary landing on a full surrogate pair re-canonicalizes to the astral 4-byte form
    // (so `"a😀b".slice(1,3) === "😀"`); a half-pair stays a lone surrogate.
    return canonicalizeSurrogates(arena, out.items);
}

/// Combine adjacent WTF-8 surrogate-pair encodings — a 3-byte high surrogate (ED A0..AF xx)
/// immediately followed by a 3-byte low surrogate (ED B0..BF xx) — into the canonical 4-byte UTF-8
/// astral scalar. Applied where a string is built from CODE UNITS (lexer `\u` escapes,
/// `String.fromCharCode`/`fromCodePoint`) so it byte-equals the same astral literal. Lone surrogates
/// are left as their 3-byte form. Fast path: a string with no 0xED byte is returned unchanged.
pub fn canonicalizeSurrogates(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0xED) == null) return s; // no surrogate-lead byte → nothing to do
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 6 <= s.len and s[i] == 0xED and s[i + 1] >= 0xA0 and s[i + 1] <= 0xAF and
            s[i + 3] == 0xED and s[i + 4] >= 0xB0 and s[i + 4] <= 0xBF)
        {
            const hi: u21 = (@as(u21, s[i] & 0x0F) << 12) | (@as(u21, s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
            const lo: u21 = (@as(u21, s[i + 3] & 0x0F) << 12) | (@as(u21, s[i + 4] & 0x3F) << 6) | (s[i + 5] & 0x3F);
            const cp: u21 = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
            // cp is in [0x10000, 0x10FFFF] → the canonical 4-byte UTF-8 form (no fallible encode).
            try out.append(arena, @intCast(0xF0 | (cp >> 18)));
            try out.append(arena, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try out.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try out.append(arena, @intCast(0x80 | (cp & 0x3F)));
            i += 6;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

/// §22.1.3.8 IsStringWellFormed — true iff `s` contains no UNPAIRED surrogate code unit. In the
/// WTF-8 store an unpaired surrogate is a 3-byte ED A0..BF sequence not immediately followed by its
/// pairing half (a high ED A0..AF then a low ED B0..BF). A canonicalized astral scalar is a 4-byte
/// F0.. sequence and is always well-formed. ASCII fast path: trivially well-formed.
pub fn isWellFormed(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, 0xED) == null) return true; // no surrogate-lead byte
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (d.cp >= 0xD800 and d.cp <= 0xDBFF) {
            // a HIGH surrogate is well-formed only when the NEXT code unit is a LOW surrogate.
            if (i + d.len >= s.len) return false;
            const next = decodeAt(s, i + d.len);
            if (next.cp < 0xDC00 or next.cp > 0xDFFF) return false;
            i += d.len + next.len; // consume the valid pair
            continue;
        }
        if (d.cp >= 0xDC00 and d.cp <= 0xDFFF) return false; // an UNPAIRED low surrogate
        i += d.len;
    }
    return true;
}

/// §22.1.3.31 ToWellFormed — replace every UNPAIRED surrogate code unit with U+FFFD (the 3-byte
/// UTF-8 replacement EF BF BD). Paired surrogates (already canonicalized to a 4-byte astral form
/// in this store) and all other code points are preserved. Fast path: a well-formed string is
/// returned unchanged.
pub fn toWellFormed(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0xED) == null) return s; // no surrogate-lead byte → unchanged
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (d.cp >= 0xD800 and d.cp <= 0xDBFF) {
            // high surrogate: keep iff immediately followed by a low surrogate (valid pair).
            if (i + d.len < s.len) {
                const next = decodeAt(s, i + d.len);
                if (next.cp >= 0xDC00 and next.cp <= 0xDFFF) {
                    try out.appendSlice(arena, s[i .. i + d.len + next.len]);
                    i += d.len + next.len;
                    continue;
                }
            }
            try out.appendSlice(arena, "\u{FFFD}"); // lone high surrogate
        } else if (d.cp >= 0xDC00 and d.cp <= 0xDFFF) {
            try out.appendSlice(arena, "\u{FFFD}"); // lone low surrogate
        } else {
            try out.appendSlice(arena, s[i .. i + d.len]);
        }
        i += d.len;
    }
    return out.toOwnedSlice(arena);
}

test "isWellFormed / toWellFormed" {
    const a = std.testing.allocator;
    try std.testing.expect(isWellFormed("abc"));
    try std.testing.expect(isWellFormed("\u{1F4A9}")); // astral pair → well-formed
    const lone = [_]u8{ 'a', 0xED, 0xA0, 0xBD, 'c' }; // a + lone high surrogate + c
    try std.testing.expect(!isWellFormed(&lone));
    const fixed = try toWellFormed(a, &lone);
    defer a.free(fixed);
    try std.testing.expectEqualSlices(u8, "a\u{FFFD}c", fixed);
}

test "canonicalize surrogate pairs" {
    const a = std.testing.allocator;
    // 😀 in WTF-8 (6 bytes) → 😀 (4-byte UTF-8 F0 9F 98 80)
    const wtf8 = [_]u8{ 0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80 };
    const got = try canonicalizeSurrogates(a, &wtf8);
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, "\u{1F600}", got);
    // a lone high surrogate is left unchanged (code-unit-identical)
    const lone = [_]u8{ 0xED, 0xA0, 0xBD };
    const lone_out = try canonicalizeSurrogates(a, &lone);
    defer a.free(lone_out);
    try std.testing.expectEqualSlices(u8, &lone, lone_out);
}

test "utf16 length and code units" {
    try std.testing.expectEqual(@as(usize, 5), utf16Length("hello"));
    try std.testing.expectEqual(@as(usize, 1), utf16Length("é")); // U+00E9, 2 bytes, 1 unit
    try std.testing.expectEqual(@as(usize, 2), utf16Length("😀")); // U+1F600, 4 bytes, 2 units
    try std.testing.expectEqual(@as(u16, 0xD83D), codeUnitAt("😀", 0).?);
    try std.testing.expectEqual(@as(u16, 0xDE00), codeUnitAt("😀", 1).?);
    try std.testing.expectEqual(@as(u16, 0x00E9), codeUnitAt("é", 0).?);
    try std.testing.expect(codeUnitAt("é", 1) == null);
}
