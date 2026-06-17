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

test "utf16 length and code units" {
    try std.testing.expectEqual(@as(usize, 5), utf16Length("hello"));
    try std.testing.expectEqual(@as(usize, 1), utf16Length("é")); // U+00E9, 2 bytes, 1 unit
    try std.testing.expectEqual(@as(usize, 2), utf16Length("😀")); // U+1F600, 4 bytes, 2 units
    try std.testing.expectEqual(@as(u16, 0xD83D), codeUnitAt("😀", 0).?);
    try std.testing.expectEqual(@as(u16, 0xDE00), codeUnitAt("😀", 1).?);
    try std.testing.expectEqual(@as(u16, 0x00E9), codeUnitAt("é", 0).?);
    try std.testing.expect(codeUnitAt("é", 1) == null);
}
