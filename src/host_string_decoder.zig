//! HOST runtime (Node axis — NOT ECMA-262): the `string_decoder` core module, i.e. the
//! `StringDecoder` class. Requireable as `require('string_decoder')` (exports = `{ StringDecoder }`).
//! Host-only — never on the Test262 path (host core modules are not requireable there).
//!
//! The whole point of `StringDecoder` is to decode a byte stream split into arbitrary chunks WITHOUT
//! mangling multibyte characters that straddle a chunk boundary: `.write(chunk)` decodes the complete
//! characters it can and BUFFERS the bytes of an incomplete trailing multibyte sequence, prepending
//! them to the next `.write`. `.end()` flushes whatever is left (incomplete sequences → U+FFFD).
//!
//! Per-instance state (mirrors Node's lib/string_decoder.js fields), held as hidden own props on the
//! instance so the Zig dispatch can read/rewrite them each call:
//!   • `"%enc%"`  — the resolved encoding name (string).
//!   • `"%buf%"`  — the buffered partial bytes as a JS Array of byte numbers (utf8/utf16le carry-over).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

const ENC_KEY = "%enc%";
const BUF_KEY = "%buf%";

const Enc = enum { utf8, ascii, latin1, hex, base64, utf16le };

// ── build the module ───────────────────────────────────────────────────────────

/// Build the `string_decoder` core-module exports object: `{ StringDecoder }`. The `StringDecoder`
/// constructor is a `.string_decoder_method` native named "StringDecoder" carrying its prototype with
/// `write`/`end`.
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const exports = try Object.create(arena, self.objectProto());

    // StringDecoder.prototype — [[Prototype]] = %Object.prototype%.
    const proto = try Object.create(arena, self.objectProto());

    const ctor = try Object.createNative(arena, .string_decoder_method, "StringDecoder");
    ctor.prototype = self.functionProto();
    try ctor.defineData("name", .{ .string = "StringDecoder" }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    for ([_][]const u8{ "write", "end" }) |name| try defineMethod(self, proto, name);

    try exports.defineData("StringDecoder", .{ .object = ctor }, true, true, true);
    return exports;
}

fn defineMethod(self: *Interpreter, target: *Object, name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .string_decoder_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

// ── dispatch ───────────────────────────────────────────────────────────────────

/// Dispatch a `.string_decoder_method` native by `func.native_name`. The constructor
/// ("StringDecoder") initializes per-instance state on the new `this_val`; `write`/`end` read the
/// receiver's hidden state.
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;

    if (eq(u8, name, "StringDecoder")) return construct(self, this_val, args);

    if (this_val != .object) return self.throwError("TypeError", "StringDecoder method called on non-object");
    const inst = this_val.object;

    if (eq(u8, name, "write")) return write(self, inst, args);
    if (eq(u8, name, "end")) return end(self, inst, args);
    return .{ .normal = .undefined };
}

/// `new StringDecoder([encoding])` — resolve the encoding (default 'utf8'), store it and an empty
/// partial-byte buffer on the instance. An unknown encoding throws ERR_UNKNOWN_ENCODING like Node.
fn construct(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (self.native_new_target == .undefined or this_val != .object) {
        // `StringDecoder(...)` without `new` is a no-op return in our host (Node returns undefined too
        // when not constructed, though it's normally used with `new`).
        return .{ .normal = this_val };
    }
    const inst = this_val.object;

    const enc_v: Value = if (args.len > 0) args[0] else .undefined;
    var enc_name: []const u8 = "utf8";
    if (enc_v != .undefined and enc_v != .null) {
        const sc = try self.toStringValuePub(enc_v);
        if (sc.isAbrupt()) return sc;
        enc_name = sc.normal.string;
        if (parseEnc(enc_name) == null) {
            const msg = std.fmt.allocPrint(self.arena, "Unknown encoding: {s}", .{enc_name}) catch return error.OutOfMemory;
            return throwCode(self, "TypeError", "ERR_UNKNOWN_ENCODING", msg);
        }
    }
    // Store the canonical lower-case name (Node exposes `.encoding`); a duped copy is durable.
    const dup = self.arena.dupe(u8, enc_name) catch return error.OutOfMemory;
    try inst.defineData(ENC_KEY, .{ .string = dup }, true, false, false);
    try inst.defineData("encoding", .{ .string = dup }, true, false, true);
    const buf = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
    try inst.defineData(BUF_KEY, .{ .object = buf }, true, false, false);
    return .{ .normal = this_val };
}

// ── per-instance state helpers ───────────────────────────────────────────────────

fn instEnc(inst: *Object) Enc {
    if (inst.get(ENC_KEY)) |v| if (v == .string) return parseEnc(v.string) orelse .utf8;
    return .utf8;
}

/// The buffered partial bytes (the `"%buf%"` Array), read into a freshly-allocated slice.
fn instBuf(self: *Interpreter, inst: *Object) EvalError![]u8 {
    const v = inst.get(BUF_KEY) orelse return self.arena.alloc(u8, 0) catch return error.OutOfMemory;
    if (v != .object) return self.arena.alloc(u8, 0) catch return error.OutOfMemory;
    const arr = v.object;
    const n = arr.array_length;
    const out = self.arena.alloc(u8, n) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = arr.arrayGet(i);
        out[i] = if (e == .number) @truncate(@as(u64, @intFromFloat(@max(@trunc(e.number), 0)))) else 0;
    }
    return out;
}

/// Rewrite the `"%buf%"` Array to hold exactly `bytes`.
fn setBuf(self: *Interpreter, inst: *Object, bytes: []const u8) EvalError!void {
    const v = inst.get(BUF_KEY) orelse blk: {
        const a = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
        try inst.defineData(BUF_KEY, .{ .object = a }, true, false, false);
        break :blk Value{ .object = a };
    };
    if (v != .object) return;
    const arr = v.object;
    try arr.arraySetLen(0);
    for (bytes, 0..) |b, i| try arr.arraySet(self.arena, i, .{ .number = @floatFromInt(b) });
}

// ── byte access ──────────────────────────────────────────────────────────────────

/// The bytes a Buffer/Uint8Array `obj` views, or null if not a byte-backed typed array.
fn bytesOf(obj: *Object) ?[]const u8 {
    const ta = obj.typed_array orelse return null;
    const ab = ta.buffer.array_buffer orelse return null;
    const start = ta.byte_offset;
    const stop = start + ta.array_length;
    if (stop > ab.bytes.len) return null;
    return ab.bytes[start..stop];
}

/// Resolve the `.write`/`.end` buffer argument to bytes: a Buffer/Uint8Array → its bytes; a string is
/// re-encoded per the decoder's encoding (Node coerces a string arg via Buffer.from(str, encoding)).
fn argBytes(self: *Interpreter, v: Value, enc: Enc) EvalError!union(enum) { bytes: []const u8, throw: Completion } {
    switch (v) {
        .object => |o| {
            if (bytesOf(o)) |b| return .{ .bytes = b };
            return .{ .throw = try throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"buf\" argument must be an instance of Buffer, TypedArray, or string.") };
        },
        .string => |s| return .{ .bytes = try encodeString(self.arena, s, enc) },
        .undefined => return .{ .bytes = &[_]u8{} },
        else => return .{ .throw = try throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"buf\" argument must be an instance of Buffer, TypedArray, or string.") },
    }
}

// ── write / end ──────────────────────────────────────────────────────────────────

/// `decoder.write(buffer)` → the decoded string for the complete characters, holding back the bytes
/// of an incomplete trailing multibyte sequence for the next call.
fn write(self: *Interpreter, inst: *Object, args: []const Value) EvalError!Completion {
    const enc = instEnc(inst);
    const ab = try argBytes(self, if (args.len > 0) args[0] else .undefined, enc);
    const incoming = switch (ab) {
        .bytes => |b| b,
        .throw => |c| return c,
    };
    const carry = try instBuf(self, inst);

    // Combine carried partial bytes + the new chunk.
    var combined = std.ArrayListUnmanaged(u8).empty;
    combined.appendSlice(self.arena, carry) catch return error.OutOfMemory;
    combined.appendSlice(self.arena, incoming) catch return error.OutOfMemory;
    const all = combined.items;

    switch (enc) {
        .utf8 => {
            const split = completeUtf8Len(all);
            const s = try decodeUtf8Lossy(self.arena, all[0..split]);
            try setBuf(self, inst, all[split..]);
            return .{ .normal = .{ .string = s } };
        },
        .utf16le => {
            // Decode whole UTF-16LE code units; hold back a trailing odd byte (and, for correctness, a
            // trailing high surrogate whose low half hasn't arrived yet).
            const split = completeUtf16Len(all);
            const s = try decodeUtf16le(self.arena, all[0..split]);
            try setBuf(self, inst, all[split..]);
            return .{ .normal = .{ .string = s } };
        },
        else => {
            // ascii / latin1 / hex / base64: no multibyte boundary buffering (each byte stands alone, or
            // — base64 — Node buffers to a 3-byte multiple; we decode whole and carry the remainder).
            if (enc == .base64) {
                const split = (all.len / 3) * 3;
                const s = try decodeWhole(self.arena, all[0..split], enc);
                try setBuf(self, inst, all[split..]);
                return .{ .normal = .{ .string = s } };
            }
            const s = try decodeWhole(self.arena, all, enc);
            try setBuf(self, inst, &[_]u8{});
            return .{ .normal = .{ .string = s } };
        },
    }
}

/// `decoder.end([buffer])` → flush. Decode any final `buffer`, then emit the buffered partial bytes,
/// with incomplete multibyte sequences becoming U+FFFD (Node's behavior).
fn end(self: *Interpreter, inst: *Object, args: []const Value) EvalError!Completion {
    var out = std.ArrayListUnmanaged(u8).empty;
    // If a final chunk is supplied, run it through write() first.
    if (args.len > 0 and args[0] != .undefined) {
        const wc = try write(self, inst, args);
        if (wc.isAbrupt()) return wc;
        if (wc.normal == .string) out.appendSlice(self.arena, wc.normal.string) catch return error.OutOfMemory;
    }
    const enc = instEnc(inst);
    const carry = try instBuf(self, inst);
    if (carry.len > 0) {
        switch (enc) {
            .utf8 => {
                // Each incomplete sequence → one U+FFFD (Node emits one replacement per held-back
                // byte's leading position; in practice an incomplete tail is a single sequence → one
                // U+FFFD).
                const fb = "\u{FFFD}";
                out.appendSlice(self.arena, fb) catch return error.OutOfMemory;
            },
            .utf16le => {
                // A leftover odd byte / lone surrogate → one U+FFFD.
                const fb = "\u{FFFD}";
                out.appendSlice(self.arena, fb) catch return error.OutOfMemory;
            },
            else => {
                const s = try decodeWhole(self.arena, carry, enc);
                out.appendSlice(self.arena, s) catch return error.OutOfMemory;
            },
        }
    }
    try setBuf(self, inst, &[_]u8{});
    return .{ .normal = .{ .string = out.items } };
}

// ── UTF-8 boundary logic ─────────────────────────────────────────────────────────

/// Given the full byte run, return the length of the prefix that contains only COMPLETE UTF-8
/// sequences — i.e. drop a trailing incomplete multibyte sequence so its bytes can be carried over.
/// A trailing run of bytes is "incomplete" only when a lead byte announces a length not yet present;
/// invalid bytes are NOT held back (they decode to U+FFFD now).
fn completeUtf8Len(b: []const u8) usize {
    if (b.len == 0) return 0;
    // Scan back over up to 3 continuation bytes (10xxxxxx) to find the last lead byte.
    var i: usize = b.len;
    var cont: usize = 0;
    while (i > 0 and cont < 4) {
        const c = b[i - 1];
        if (c & 0xC0 == 0x80) {
            // continuation byte
            cont += 1;
            i -= 1;
            continue;
        }
        // `c` is a lead (or ASCII / invalid) byte at index i-1; the candidate sequence is b[i-1..].
        const lead = c;
        const need: usize = if (lead < 0x80) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 0;
        const have = b.len - (i - 1);
        if (need == 0) return b.len; // invalid lead → not held back; decoded as U+FFFD now
        if (have < need) return i - 1; // incomplete: hold back from this lead byte onward
        return b.len; // the trailing sequence is complete
    }
    // Either all-continuation (invalid) or 4+ continuation bytes: nothing to hold back.
    return b.len;
}

/// Decode a COMPLETE-sequence UTF-8 byte run to a WTF-8 JS string, replacing any invalid bytes with
/// U+FFFD (Node's lossy decode). The input is guaranteed to end on a sequence boundary by the caller.
fn decodeUtf8Lossy(arena: std.mem.Allocator, b: []const u8) EvalError![]const u8 {
    // Fast path: already valid UTF-8 → dupe verbatim.
    if (std.unicode.utf8ValidateSlice(b)) return arena.dupe(u8, b) catch return error.OutOfMemory;
    var out = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < b.len) {
        const len = std.unicode.utf8ByteSequenceLength(b[i]) catch {
            // Invalid lead → emit U+FFFD, advance one byte.
            out.appendSlice(arena, "\u{FFFD}") catch return error.OutOfMemory;
            i += 1;
            continue;
        };
        if (i + len > b.len) {
            out.appendSlice(arena, "\u{FFFD}") catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(b[i .. i + len]) catch {
            out.appendSlice(arena, "\u{FFFD}") catch return error.OutOfMemory;
            i += 1;
            continue;
        };
        var enc_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc_buf) catch {
            out.appendSlice(arena, "\u{FFFD}") catch return error.OutOfMemory;
            i += len;
            continue;
        };
        out.appendSlice(arena, enc_buf[0..n]) catch return error.OutOfMemory;
        i += len;
    }
    return out.items;
}

// ── UTF-16LE boundary logic ──────────────────────────────────────────────────────

/// Length of the prefix of `b` decodable as complete UTF-16LE: an even number of bytes, and not
/// ending on a lone high surrogate (whose low half hasn't arrived). The odd trailing byte and/or
/// pending high surrogate are held back.
fn completeUtf16Len(b: []const u8) usize {
    var n = b.len - (b.len % 2);
    // If the last complete code unit is a high surrogate (0xD800–0xDBFF), hold it (and the odd byte)
    // back so its low surrogate can join it next chunk.
    if (n >= 2) {
        const u: u16 = @as(u16, b[n - 2]) | (@as(u16, b[n - 1]) << 8);
        if (u >= 0xD800 and u <= 0xDBFF) n -= 2;
    }
    return n;
}

/// Decode UTF-16LE bytes (length already even, no trailing lone high surrogate) to a WTF-8 string.
/// Lone surrogates are emitted as WTF-8 (3 bytes), matching ljs's surrogate-preserving storage.
fn decodeUtf16le(arena: std.mem.Allocator, b: []const u8) EvalError![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i + 2 <= b.len) : (i += 2) {
        const u: u16 = @as(u16, b[i]) | (@as(u16, b[i + 1]) << 8);
        if (u >= 0xD800 and u <= 0xDBFF and i + 4 <= b.len) {
            const lo: u16 = @as(u16, b[i + 2]) | (@as(u16, b[i + 3]) << 8);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                const cp: u21 = 0x10000 + ((@as(u21, u - 0xD800) << 10) | (lo - 0xDC00));
                var enc_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &enc_buf) catch 0;
                out.appendSlice(arena, enc_buf[0..n]) catch return error.OutOfMemory;
                i += 2;
                continue;
            }
        }
        // BMP code unit (or lone surrogate) → WTF-8 (encode the raw code unit value).
        var enc_buf: [4]u8 = undefined;
        const n = wtf8Encode(u, &enc_buf);
        out.appendSlice(arena, enc_buf[0..n]) catch return error.OutOfMemory;
    }
    return out.items;
}

/// Encode a single 16-bit code unit (possibly a lone surrogate) as WTF-8 into `out`, returning the
/// byte count. Mirrors UTF-8 encoding but permits the surrogate range.
fn wtf8Encode(u: u16, out: *[4]u8) usize {
    const cp: u21 = u;
    if (cp < 0x80) {
        out[0] = @truncate(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @truncate(0xC0 | (cp >> 6));
        out[1] = @truncate(0x80 | (cp & 0x3F));
        return 2;
    } else {
        out[0] = @truncate(0xE0 | (cp >> 12));
        out[1] = @truncate(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @truncate(0x80 | (cp & 0x3F));
        return 3;
    }
}

// ── whole-buffer encodings (no boundary state) ───────────────────────────────────

/// Decode a complete byte run per `enc` for the non-streaming encodings (ascii/latin1/hex/base64).
fn decodeWhole(arena: std.mem.Allocator, b: []const u8, enc: Enc) EvalError![]const u8 {
    switch (enc) {
        .ascii, .latin1 => {
            var out = std.ArrayListUnmanaged(u8).empty;
            for (b) |byte| {
                const cp: u21 = if (enc == .ascii) byte & 0x7f else byte;
                var enc_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &enc_buf) catch 1;
                out.appendSlice(arena, enc_buf[0..n]) catch return error.OutOfMemory;
            }
            return out.items;
        },
        .hex => {
            const out = arena.alloc(u8, b.len * 2) catch return error.OutOfMemory;
            const digits = "0123456789abcdef";
            for (b, 0..) |byte, i| {
                out[i * 2] = digits[byte >> 4];
                out[i * 2 + 1] = digits[byte & 0x0f];
            }
            return out;
        },
        .base64 => {
            const enc64 = std.base64.standard.Encoder;
            const out = arena.alloc(u8, enc64.calcSize(b.len)) catch return error.OutOfMemory;
            return enc64.encode(out, b);
        },
        else => return arena.dupe(u8, b) catch return error.OutOfMemory,
    }
}

/// Re-encode a JS string (WTF-8 bytes) to raw bytes per `enc` (for a string `.write` argument).
fn encodeString(arena: std.mem.Allocator, s: []const u8, enc: Enc) EvalError![]const u8 {
    switch (enc) {
        .utf8 => return arena.dupe(u8, s) catch return error.OutOfMemory,
        .ascii, .latin1 => {
            var out = std.ArrayListUnmanaged(u8).empty;
            var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                const b: u8 = @truncate(cp);
                out.append(arena, if (enc == .ascii) b & 0x7f else b) catch return error.OutOfMemory;
            }
            return out.items;
        },
        .utf16le => {
            var out = std.ArrayListUnmanaged(u8).empty;
            var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                if (cp > 0xFFFF) {
                    const v = cp - 0x10000;
                    const hi: u16 = @truncate(0xD800 + (v >> 10));
                    const lo: u16 = @truncate(0xDC00 + (v & 0x3FF));
                    out.append(arena, @truncate(hi)) catch return error.OutOfMemory;
                    out.append(arena, @truncate(hi >> 8)) catch return error.OutOfMemory;
                    out.append(arena, @truncate(lo)) catch return error.OutOfMemory;
                    out.append(arena, @truncate(lo >> 8)) catch return error.OutOfMemory;
                } else {
                    const u: u16 = @truncate(cp);
                    out.append(arena, @truncate(u)) catch return error.OutOfMemory;
                    out.append(arena, @truncate(u >> 8)) catch return error.OutOfMemory;
                }
            }
            return out.items;
        },
        .hex => {
            var out = std.ArrayListUnmanaged(u8).empty;
            var i: usize = 0;
            while (i + 2 <= s.len) : (i += 2) {
                const hi = hexDigit(s[i]) orelse break;
                const lo = hexDigit(s[i + 1]) orelse break;
                out.append(arena, hi * 16 + lo) catch return error.OutOfMemory;
            }
            return out.items;
        },
        .base64 => {
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(s) catch return arena.alloc(u8, 0) catch return error.OutOfMemory;
            const out = arena.alloc(u8, n) catch return error.OutOfMemory;
            dec.decode(out, s) catch return arena.alloc(u8, 0) catch return error.OutOfMemory;
            return out;
        },
    }
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ── encoding name parsing + error helper ─────────────────────────────────────────

fn parseEnc(name: []const u8) ?Enc {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "utf8") or eq(name, "utf-8")) return .utf8;
    if (eq(name, "ascii")) return .ascii;
    if (eq(name, "latin1") or eq(name, "binary")) return .latin1;
    if (eq(name, "hex")) return .hex;
    if (eq(name, "base64") or eq(name, "base64url")) return .base64;
    if (eq(name, "utf16le") or eq(name, "ucs2") or eq(name, "ucs-2") or eq(name, "utf-16le")) return .utf16le;
    return null;
}

/// Throw a Node-style error carrying a `code` property (e.g. "ERR_UNKNOWN_ENCODING").
fn throwCode(self: *Interpreter, kind: []const u8, code: []const u8, msg: []const u8) EvalError!Completion {
    const arena = self.arena;
    const err = try Object.create(arena, self.errorProto(kind));
    err.error_data = true;
    try err.set("name", .{ .string = kind });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = code }, true, false, true);
    return .{ .throw = .{ .object = err } };
}
