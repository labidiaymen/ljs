//! HOST runtime (Node axis, spec 108 — NOT ECMA-262): a MINIMAL `crypto` core module that common
//! packages (e.g. `uuid`, `nanoid`) reach for: `randomBytes`, `randomFillSync`, `randomUUID`,
//! `getRandomValues`, `randomInt`, `createHash` (md5/sha1/sha224/sha256/sha384/sha512 via
//! `std.crypto.hash`), `createHmac` (same algos via `std.crypto.auth.hmac`), `pbkdf2Sync`
//! (`std.crypto.pwhash.pbkdf2`), and `timingSafeEqual`. Randomness comes from the host `Io` CSPRNG
//! (`self.io.random`). HOST-only (`require('crypto')` / `require('node:crypto')`; the Web-Crypto
//! subset is also installed as a global). NOT a full crypto implementation — no ciphers/keys;
//! absent rather than wrong.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_buffer = @import("host_buffer.zig");

/// Build the `crypto` core-module exports.
pub fn build(self: *Interpreter) EvalError!*Object {
    const obj = try Object.create(self.arena, self.objectProto());
    for ([_][]const u8{ "randomBytes", "randomFillSync", "randomUUID", "getRandomValues", "randomInt", "createHash", "createHmac", "pbkdf2Sync", "timingSafeEqual" }) |m|
        try defineMethod(self, obj, m);
    // `crypto.webcrypto` self-reference (some packages read `crypto.webcrypto.getRandomValues`).
    try obj.defineData("webcrypto", .{ .object = obj }, true, true, true);
    return obj;
}

/// Build the Web-Crypto GLOBAL object (`globalThis.crypto`) — the subset Node ≥ 20 / browsers expose:
/// `getRandomValues` + `randomUUID` (no `subtle` yet). Installed as a global by `host_setup`.
pub fn buildWebCrypto(self: *Interpreter) EvalError!*Object {
    const obj = try Object.create(self.arena, self.objectProto());
    for ([_][]const u8{ "getRandomValues", "randomUUID" }) |m|
        try defineMethod(self, obj, m);
    return obj;
}

fn defineMethod(self: *Interpreter, target: *Object, name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .crypto_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

/// Dispatch a `.crypto_method` native by `func.native_name`. Statics are unprefixed; the `Hash`
/// instance methods are `h.update`/`h.digest` (receiver = `this_val`).
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    const name = func.native_name;
    const eq = std.mem.eql;
    if (eq(u8, name, "randomBytes")) return randomBytes(self, args);
    if (eq(u8, name, "randomFillSync")) return randomFill(self, args);
    if (eq(u8, name, "getRandomValues")) return getRandomValues(self, args);
    if (eq(u8, name, "randomUUID")) return randomUUID(self);
    if (eq(u8, name, "randomInt")) return randomInt(self, args);
    if (eq(u8, name, "createHash")) return createHash(self, args);
    if (eq(u8, name, "createHmac")) return createHmac(self, args);
    if (eq(u8, name, "pbkdf2Sync")) return pbkdf2Sync(self, args);
    if (eq(u8, name, "timingSafeEqual")) return timingSafeEqual(self, args);
    if (eq(u8, name, "h.update")) return hashUpdate(self, this_val, args);
    if (eq(u8, name, "h.digest")) return hashDigest(self, this_val, args);
    if (eq(u8, name, "m.update")) return hmacUpdate(self, this_val, args);
    if (eq(u8, name, "m.digest")) return hmacDigest(self, this_val, args);
    return .{ .normal = .undefined };
}

// ── createHash (md5 / sha1 / sha256 / sha512) ─────────────────────────────────────────────────────

const ALGO_KEY = "%algo%";
const BUF_KEY = "%buf%";

/// `crypto.createHash(algorithm)` → a Hash object with `update(data)` / `digest([enc])`. State (the
/// algorithm + accumulated bytes) lives in hidden own props; `update` accumulates, `digest` finalizes.
fn createHash(self: *Interpreter, args: []const Value) EvalError!Completion {
    const algo_v = if (args.len > 0) args[0] else .undefined;
    if (algo_v != .string) return self.throwError("TypeError", "algorithm must be a string");
    const h = try Object.create(self.arena, self.objectProto());
    try h.defineData(ALGO_KEY, .{ .string = try self.arena.dupe(u8, algo_v.string) }, false, false, false);
    const empty = try host_buffer.makeBufferFromBytes(self, "");
    try h.defineData(BUF_KEY, .{ .object = empty }, true, false, false);
    try defineHashMethod(self, h, "update", "h.update");
    try defineHashMethod(self, h, "digest", "h.digest");
    return .{ .normal = .{ .object = h } };
}

fn defineHashMethod(self: *Interpreter, target: *Object, key: []const u8, native_name: []const u8) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .crypto_method, native_name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = key }, false, false, true);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

fn hashUpdate(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Hash.update called on non-object");
    const h = this_val.object;
    const prev = bytesOf(h.get(BUF_KEY) orelse .undefined) orelse "";
    const add = bytesOf(if (args.len > 0) args[0] else .undefined) orelse blk: {
        // A string with no encoding arg → its UTF-8 bytes.
        if (args.len > 0 and args[0] == .string) break :blk args[0].string;
        break :blk "";
    };
    const joined = self.arena.alloc(u8, prev.len + add.len) catch return error.OutOfMemory;
    @memcpy(joined[0..prev.len], prev);
    @memcpy(joined[prev.len..], add);
    const nbuf = try host_buffer.makeBufferFromBytes(self, joined);
    try h.defineData(BUF_KEY, .{ .object = nbuf }, true, false, false);
    return .{ .normal = this_val };
}

fn hashDigest(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Hash.digest called on non-object");
    const h = this_val.object;
    const algo = if (h.get(ALGO_KEY)) |v| (if (v == .string) v.string else "") else "";
    const data = bytesOf(h.get(BUF_KEY) orelse .undefined) orelse "";

    var buf: [64]u8 = undefined;
    const digest = computeDigest(algo, data, &buf) orelse return self.throwError("Error", "Digest method not supported");
    return encodeDigest(self, digest, if (args.len > 0) args[0] else .undefined);
}

/// Format a finalized `digest` per an optional encoding arg: `'hex'`/`'base64'`/`'latin1'`/`'binary'`
/// → a string; anything else (incl. `undefined`) → a Buffer. Shared by `Hash` and `Hmac`.
fn encodeDigest(self: *Interpreter, digest: []const u8, enc_v: Value) EvalError!Completion {
    if (enc_v == .string) {
        const enc = enc_v.string;
        if (std.mem.eql(u8, enc, "hex")) {
            const out = self.arena.alloc(u8, digest.len * 2) catch return error.OutOfMemory;
            const hex = "0123456789abcdef";
            for (digest, 0..) |b, i| {
                out[i * 2] = hex[b >> 4];
                out[i * 2 + 1] = hex[b & 0x0f];
            }
            return .{ .normal = .{ .string = out } };
        }
        if (std.mem.eql(u8, enc, "base64")) {
            const Enc = std.base64.standard.Encoder;
            const out = self.arena.alloc(u8, Enc.calcSize(digest.len)) catch return error.OutOfMemory;
            return .{ .normal = .{ .string = Enc.encode(out, digest) } };
        }
        if (std.mem.eql(u8, enc, "latin1") or std.mem.eql(u8, enc, "binary")) {
            // latin1: each byte is one code point; the string storage is WTF-8 (1-2 bytes/code point).
            var nbytes: usize = 0;
            for (digest) |b| nbytes += @as(usize, if (b < 0x80) 1 else 2);
            const out = self.arena.alloc(u8, nbytes) catch return error.OutOfMemory;
            var i: usize = 0;
            for (digest) |b| {
                if (b < 0x80) {
                    out[i] = b;
                    i += 1;
                } else {
                    out[i] = 0xc0 | (b >> 6);
                    out[i + 1] = 0x80 | (b & 0x3f);
                    i += 2;
                }
            }
            return .{ .normal = .{ .string = out } };
        }
    }
    const out_buf = try host_buffer.makeBufferFromBytes(self, digest);
    return .{ .normal = .{ .object = out_buf } };
}

/// Compute `algorithm`'s digest of `data` into `out` (≤ 64 bytes), returning the used slice, or null
/// for an unsupported algorithm.
fn computeDigest(algo: []const u8, data: []const u8, out: *[64]u8) ?[]u8 {
    const eq = std.mem.eql;
    if (eq(u8, algo, "md5")) {
        std.crypto.hash.Md5.hash(data, out[0..16], .{});
        return out[0..16];
    }
    if (eq(u8, algo, "sha1")) {
        std.crypto.hash.Sha1.hash(data, out[0..20], .{});
        return out[0..20];
    }
    if (eq(u8, algo, "sha224")) {
        std.crypto.hash.sha2.Sha224.hash(data, out[0..28], .{});
        return out[0..28];
    }
    if (eq(u8, algo, "sha256")) {
        std.crypto.hash.sha2.Sha256.hash(data, out[0..32], .{});
        return out[0..32];
    }
    if (eq(u8, algo, "sha384")) {
        std.crypto.hash.sha2.Sha384.hash(data, out[0..48], .{});
        return out[0..48];
    }
    if (eq(u8, algo, "sha512")) {
        std.crypto.hash.sha2.Sha512.hash(data, out[0..64], .{});
        return out[0..64];
    }
    return null;
}

// ── createHmac (md5 / sha1 / sha224 / sha256 / sha384 / sha512) ─────────────────────────────────────

const KEY_KEY = "%key%";

/// `crypto.createHmac(algorithm, key)` → an Hmac object with `update(data)` / `digest([enc])`. Like
/// `createHash`, the algorithm + key + accumulated bytes live in hidden own props; the MAC is computed
/// one-shot at `digest` time (HMAC is deterministic, so accumulate-then-finalize is identical).
fn createHmac(self: *Interpreter, args: []const Value) EvalError!Completion {
    const algo_v = if (args.len > 0) args[0] else .undefined;
    if (algo_v != .string) return self.throwError("TypeError", "algorithm must be a string");
    const key_bytes = bytesOf(if (args.len > 1) args[1] else .undefined) orelse
        return self.throwError("TypeError", "key must be a string or Buffer");
    if (!hmacSupported(algo_v.string)) return self.throwError("Error", "Digest method not supported");
    const m = try Object.create(self.arena, self.objectProto());
    try m.defineData(ALGO_KEY, .{ .string = try self.arena.dupe(u8, algo_v.string) }, false, false, false);
    const key_buf = try host_buffer.makeBufferFromBytes(self, key_bytes);
    try m.defineData(KEY_KEY, .{ .object = key_buf }, false, false, false);
    const empty = try host_buffer.makeBufferFromBytes(self, "");
    try m.defineData(BUF_KEY, .{ .object = empty }, true, false, false);
    try defineHashMethod(self, m, "update", "m.update");
    try defineHashMethod(self, m, "digest", "m.digest");
    return .{ .normal = .{ .object = m } };
}

fn hmacUpdate(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Hmac.update called on non-object");
    const m = this_val.object;
    const prev = bytesOf(m.get(BUF_KEY) orelse .undefined) orelse "";
    const add = bytesOf(if (args.len > 0) args[0] else .undefined) orelse "";
    const joined = self.arena.alloc(u8, prev.len + add.len) catch return error.OutOfMemory;
    @memcpy(joined[0..prev.len], prev);
    @memcpy(joined[prev.len..], add);
    const nbuf = try host_buffer.makeBufferFromBytes(self, joined);
    try m.defineData(BUF_KEY, .{ .object = nbuf }, true, false, false);
    return .{ .normal = this_val };
}

fn hmacDigest(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
    if (this_val != .object) return self.throwError("TypeError", "Hmac.digest called on non-object");
    const m = this_val.object;
    const algo = if (m.get(ALGO_KEY)) |v| (if (v == .string) v.string else "") else "";
    const key = bytesOf(m.get(KEY_KEY) orelse .undefined) orelse "";
    const data = bytesOf(m.get(BUF_KEY) orelse .undefined) orelse "";

    var buf: [64]u8 = undefined;
    const mac = computeHmac(algo, key, data, &buf) orelse return self.throwError("Error", "Digest method not supported");
    return encodeDigest(self, mac, if (args.len > 0) args[0] else .undefined);
}

fn hmacSupported(algo: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, algo, "md5") or eq(u8, algo, "sha1") or eq(u8, algo, "sha224") or
        eq(u8, algo, "sha256") or eq(u8, algo, "sha384") or eq(u8, algo, "sha512");
}

/// HMAC of `data` under `key` for `algorithm` into `out` (≤ 64 bytes), returning the used slice, or
/// null for an unsupported algorithm.
fn computeHmac(algo: []const u8, key: []const u8, data: []const u8, out: *[64]u8) ?[]u8 {
    const eq = std.mem.eql;
    const hmac = std.crypto.auth.hmac;
    if (eq(u8, algo, "md5")) {
        hmac.Hmac(std.crypto.hash.Md5).create(out[0..16], data, key);
        return out[0..16];
    }
    if (eq(u8, algo, "sha1")) {
        hmac.Hmac(std.crypto.hash.Sha1).create(out[0..20], data, key);
        return out[0..20];
    }
    if (eq(u8, algo, "sha224")) {
        hmac.Hmac(std.crypto.hash.sha2.Sha224).create(out[0..28], data, key);
        return out[0..28];
    }
    if (eq(u8, algo, "sha256")) {
        hmac.Hmac(std.crypto.hash.sha2.Sha256).create(out[0..32], data, key);
        return out[0..32];
    }
    if (eq(u8, algo, "sha384")) {
        hmac.Hmac(std.crypto.hash.sha2.Sha384).create(out[0..48], data, key);
        return out[0..48];
    }
    if (eq(u8, algo, "sha512")) {
        hmac.Hmac(std.crypto.hash.sha2.Sha512).create(out[0..64], data, key);
        return out[0..64];
    }
    return null;
}

// ── pbkdf2Sync (sha1 / sha224 / sha256 / sha384 / sha512) ────────────────────────────────────────────

/// `crypto.pbkdf2Sync(password, salt, iterations, keylen, digest)` → a Buffer of `keylen` derived bytes
/// via `std.crypto.pwhash.pbkdf2` with the named HMAC PRF. `password`/`salt` may be strings or Buffers.
fn pbkdf2Sync(self: *Interpreter, args: []const Value) EvalError!Completion {
    const password = bytesOf(if (args.len > 0) args[0] else .undefined) orelse
        return self.throwError("TypeError", "password must be a string or Buffer");
    const salt = bytesOf(if (args.len > 1) args[1] else .undefined) orelse
        return self.throwError("TypeError", "salt must be a string or Buffer");
    const iter_c = try self.toNumberV(if (args.len > 2) args[2] else .undefined);
    if (iter_c.isAbrupt()) return iter_c;
    const klen_c = try self.toNumberV(if (args.len > 3) args[3] else .undefined);
    if (klen_c.isAbrupt()) return klen_c;
    const iter_n = iter_c.normal.number;
    const klen_n = klen_c.normal.number;
    if (std.math.isNan(iter_n) or iter_n < 1 or iter_n > 0x7fff_ffff)
        return self.throwError("RangeError", "iterations must be a positive integer");
    if (std.math.isNan(klen_n) or klen_n < 0 or klen_n > 0x7fff_ffff)
        return self.throwError("RangeError", "invalid keylen");
    const digest_v = if (args.len > 4) args[4] else .undefined;
    if (digest_v != .string) return self.throwError("TypeError", "digest must be a string");
    const rounds: u32 = @intFromFloat(iter_n);
    const keylen: usize = @intFromFloat(klen_n);

    const dk = self.arena.alloc(u8, keylen) catch return error.OutOfMemory;
    const eq = std.mem.eql;
    const hmac = std.crypto.auth.hmac;
    const digest = digest_v.string;
    if (eq(u8, digest, "sha1")) {
        pbkdf2Run(hmac.HmacSha1, dk, password, salt, rounds) catch return self.throwError("Error", "pbkdf2 failed");
    } else if (eq(u8, digest, "sha224")) {
        pbkdf2Run(hmac.sha2.HmacSha224, dk, password, salt, rounds) catch return self.throwError("Error", "pbkdf2 failed");
    } else if (eq(u8, digest, "sha256")) {
        pbkdf2Run(hmac.sha2.HmacSha256, dk, password, salt, rounds) catch return self.throwError("Error", "pbkdf2 failed");
    } else if (eq(u8, digest, "sha384")) {
        pbkdf2Run(hmac.sha2.HmacSha384, dk, password, salt, rounds) catch return self.throwError("Error", "pbkdf2 failed");
    } else if (eq(u8, digest, "sha512")) {
        pbkdf2Run(hmac.sha2.HmacSha512, dk, password, salt, rounds) catch return self.throwError("Error", "pbkdf2 failed");
    } else {
        return self.throwError("Error", "Digest method not supported");
    }
    const out_buf = try host_buffer.makeBufferFromBytes(self, dk);
    return .{ .normal = .{ .object = out_buf } };
}

fn pbkdf2Run(comptime Prf: type, dk: []u8, password: []const u8, salt: []const u8, rounds: u32) !void {
    try std.crypto.pwhash.pbkdf2(dk, password, salt, rounds, Prf);
}

// ── timingSafeEqual ──────────────────────────────────────────────────────────────────────────────────

/// `crypto.timingSafeEqual(a, b)` → boolean. Constant-time comparison of two equal-length byte views;
/// throws `RangeError` when the lengths differ (matching Node).
fn timingSafeEqual(self: *Interpreter, args: []const Value) EvalError!Completion {
    const a = bytesOf(if (args.len > 0) args[0] else .undefined) orelse
        return self.throwError("TypeError", "arguments must be Buffers/TypedArrays");
    const b = bytesOf(if (args.len > 1) args[1] else .undefined) orelse
        return self.throwError("TypeError", "arguments must be Buffers/TypedArrays");
    if (a.len != b.len) return self.throwError("RangeError", "Input buffers must have the same byte length");
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return .{ .normal = .{ .boolean = diff == 0 } };
}

/// Raw bytes of a string / Buffer / TypedArray value, or null.
fn bytesOf(v: Value) ?[]const u8 {
    if (v == .string) return v.string;
    if (v == .object) {
        if (v.object.typed_array) |ta| {
            if (ta.buffer.array_buffer) |ab| {
                const start = ta.byte_offset;
                const end = start + ta.array_length * ta.elem.bytesPerElement();
                if (end <= ab.bytes.len) return ab.bytes[start..end];
            }
        }
    }
    return null;
}

/// `crypto.randomBytes(size)` → a Buffer of `size` cryptographically-random bytes.
fn randomBytes(self: *Interpreter, args: []const Value) EvalError!Completion {
    const nd = try self.toNumberV(if (args.len > 0) args[0] else .undefined);
    if (nd.isAbrupt()) return nd;
    const n = nd.normal.number;
    if (std.math.isNan(n) or n < 0 or n > 0x7fff_ffff) return self.throwError("RangeError", "invalid size");
    const size: usize = @intFromFloat(n);
    const bytes = self.arena.alloc(u8, size) catch return error.OutOfMemory;
    self.io.random(bytes);
    const buf = try host_buffer.makeBufferFromBytes(self, bytes);
    return .{ .normal = .{ .object = buf } };
}

/// Fill the bytes of a Buffer/Uint8Array (`randomFillSync(buf)` / Web-Crypto `getRandomValues(buf)`)
/// with random data and return the same object.
fn fillView(self: *Interpreter, args: []const Value) EvalError!?Value {
    const v = if (args.len > 0) args[0] else .undefined;
    if (v != .object) return null;
    const ta = v.object.typed_array orelse return null;
    const ab = ta.buffer.array_buffer orelse return null;
    const bpe = ta.elem.bytesPerElement();
    const start = ta.byte_offset;
    const end = start + ta.array_length * bpe;
    if (end > ab.bytes.len) return null;
    self.io.random(ab.bytes[start..end]);
    return v;
}

fn randomFill(self: *Interpreter, args: []const Value) EvalError!Completion {
    if (try fillView(self, args)) |v| return .{ .normal = v };
    return self.throwError("TypeError", "argument must be a Buffer/TypedArray");
}

fn getRandomValues(self: *Interpreter, args: []const Value) EvalError!Completion {
    if (try fillView(self, args)) |v| return .{ .normal = v };
    return self.throwError("TypeError", "argument must be an integer-typed TypedArray");
}

/// `crypto.randomUUID()` → an RFC 4122 v4 UUID string.
fn randomUUID(self: *Interpreter) EvalError!Completion {
    var b: [16]u8 = undefined;
    self.io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var oi: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[byte >> 4];
        out[oi + 1] = hex[byte & 0x0f];
        oi += 2;
    }
    const s = self.arena.dupe(u8, &out) catch return error.OutOfMemory;
    return .{ .normal = .{ .string = s } };
}

/// `crypto.randomInt([min,] max)` → a uniform random integer in [min, max).
fn randomInt(self: *Interpreter, args: []const Value) EvalError!Completion {
    var lo: f64 = 0;
    var hi: f64 = 0;
    if (args.len >= 2) {
        const a = try self.toNumberV(args[0]);
        if (a.isAbrupt()) return a;
        const b = try self.toNumberV(args[1]);
        if (b.isAbrupt()) return b;
        lo = a.normal.number;
        hi = b.normal.number;
    } else if (args.len == 1) {
        const b = try self.toNumberV(args[0]);
        if (b.isAbrupt()) return b;
        hi = b.normal.number;
    }
    if (!(hi > lo)) return self.throwError("RangeError", "max must be greater than min");
    const range: u64 = @intFromFloat(hi - lo);
    var rb: [8]u8 = undefined;
    self.io.random(&rb);
    const r = std.mem.readInt(u64, &rb, .little) % @max(range, 1);
    return .{ .normal = .{ .number = lo + @as(f64, @floatFromInt(r)) } };
}
