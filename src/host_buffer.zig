//! HOST runtime (Node axis, spec 101 — NOT ECMA-262): Node's `Buffer`. A `Buffer` instance is a
//! real byte-backed `Uint8Array` (a typed-array view over a fresh `ArrayBuffer`) whose `[[Prototype]]`
//! is `Buffer.prototype` (which in turn inherits `%Uint8Array.prototype%`), so indexing, `.length`,
//! iteration, `instanceof Uint8Array`, and the inherited TypedArray methods all work, while the
//! Buffer-specific methods resolve on `Buffer.prototype`. Installed host-only via `host_setup`.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

// ── install ──────────────────────────────────────────────────────────────────

/// Build + declare the `Buffer` global (a function) with its statics and `Buffer.prototype` (whose
/// [[Prototype]] is %Uint8Array.prototype%). Called from `host_setup.installHostGlobals`.
pub fn installBuffer(self: *Interpreter, function_proto: ?*Object) EvalError!void {
    const arena = self.arena;
    const env = self.globals orelse return;
    const u8_proto = self.globalProto("Uint8Array"); // Buffer.prototype inherits from this

    // Buffer.prototype (proto = %Uint8Array.prototype%) — holds the Buffer-specific methods.
    const proto = try Object.create(arena, u8_proto);

    // The Buffer constructor function.
    const ctor = try Object.createNative(arena, .buffer_fn, "Buffer");
    ctor.prototype = function_proto;
    try ctor.defineData("name", .{ .string = "Buffer" }, false, false, true);
    try ctor.defineData("prototype", .{ .object = proto }, false, false, false);
    try proto.defineData("constructor", .{ .object = ctor }, true, false, true);

    // Statics.
    for ([_][]const u8{ "alloc", "allocUnsafe", "allocUnsafeSlow", "from", "isBuffer", "byteLength", "concat" }) |name|
        try defineMethod(self, ctor, name, function_proto);
    // Prototype methods.
    for ([_][]const u8{
        "toString",      "write",         "slice",        "subarray",     "equals",
        "toJSON",        "readUInt8",     "writeUInt8",   "readUInt16LE", "readUInt16BE",
        "writeUInt16LE", "writeUInt16BE", "readUInt32LE", "readUInt32BE", "writeUInt32LE",
        "writeUInt32BE",
    }) |name|
        try defineMethod(self, proto, name, function_proto);

    try env.declare("Buffer", .{ .object = ctor }, true, true);
    if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
        try gb.value.object.defineData("Buffer", .{ .object = ctor }, true, false, true);
}

fn defineMethod(self: *Interpreter, target: *Object, name: []const u8, function_proto: ?*Object) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .buffer_fn, name);
    fn_obj.prototype = function_proto;
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

// ── byte storage helpers ─────────────────────────────────────────────────────

/// The mutable byte slice a Buffer/Uint8Array `obj` views (its `array_length` bytes at `byte_offset`
/// of the backing ArrayBuffer), or null if `obj` is not a byte-backed typed array.
fn bytesOf(obj: *Object) ?[]u8 {
    const ta = obj.typed_array orelse return null;
    const ab = ta.buffer.array_buffer orelse return null;
    const start = ta.byte_offset;
    const end = start + ta.array_length;
    if (end > ab.bytes.len) return null;
    return ab.bytes[start..end];
}

/// Create a fresh zero-filled Buffer of `n` bytes (a Uint8Array over a new ArrayBuffer, reproto'd to
/// Buffer.prototype).
fn makeBuffer(self: *Interpreter, n: usize) EvalError!*Object {
    const ab = Object.createArrayBuffer(self.arena, self.globalProto("ArrayBuffer"), n, null) catch return error.OutOfMemory;
    const proto = self.globalProto("Buffer") orelse self.globalProto("Uint8Array");
    return Object.createTypedArray(self.arena, proto, ab, 0, n, .u8) catch return error.OutOfMemory;
}

pub fn makeBufferFromBytes(self: *Interpreter, src: []const u8) EvalError!*Object {
    const buf = try makeBuffer(self, src.len);
    if (bytesOf(buf)) |dst| @memcpy(dst, src);
    return buf;
}

// ── encodings ────────────────────────────────────────────────────────────────

const Enc = enum { utf8, hex, base64, latin1, ascii, utf16le };

fn parseEnc(name: []const u8) Enc {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "hex")) return .hex;
    if (eq(name, "base64") or eq(name, "base64url")) return .base64;
    if (eq(name, "latin1") or eq(name, "binary")) return .latin1;
    if (eq(name, "ascii")) return .ascii;
    if (eq(name, "utf16le") or eq(name, "ucs2") or eq(name, "ucs-2") or eq(name, "utf-16le")) return .utf16le;
    return .utf8; // "utf8"/"utf-8"/unknown
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Encode a JS string (WTF-8 bytes) to Buffer bytes per `enc`.
fn encode(arena: std.mem.Allocator, s: []const u8, enc: Enc) EvalError![]u8 {
    switch (enc) {
        .utf8 => return arena.dupe(u8, s) catch return error.OutOfMemory,
        .hex => {
            var out: std.ArrayListUnmanaged(u8) = .empty;
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
        .latin1, .ascii => {
            // Each code point → one byte (latin1 keeps low 8 bits; ascii masks to 7 bits).
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                const b: u8 = @truncate(cp);
                out.append(arena, if (enc == .ascii) b & 0x7f else b) catch return error.OutOfMemory;
            }
            return out.items;
        },
        .utf16le => {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                const u: u16 = @truncate(cp); // BMP first cut
                out.append(arena, @truncate(u)) catch return error.OutOfMemory;
                out.append(arena, @truncate(u >> 8)) catch return error.OutOfMemory;
            }
            return out.items;
        },
    }
}

/// Decode Buffer bytes to a JS string (WTF-8) per `enc`.
fn decode(arena: std.mem.Allocator, b: []const u8, enc: Enc) EvalError![]const u8 {
    switch (enc) {
        .utf8 => return arena.dupe(u8, b) catch return error.OutOfMemory,
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
        .latin1, .ascii => {
            // Each byte → a code point (0–255 latin1, &0x7f ascii) → UTF-8.
            var out: std.ArrayListUnmanaged(u8) = .empty;
            for (b) |byte| {
                const cp: u21 = if (enc == .ascii) byte & 0x7f else byte;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 1;
                out.appendSlice(arena, buf[0..n]) catch return error.OutOfMemory;
            }
            return out.items;
        },
        .utf16le => {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var i: usize = 0;
            while (i + 1 < b.len + 1 and i + 2 <= b.len) : (i += 2) {
                const u: u16 = @as(u16, b[i]) | (@as(u16, b[i + 1]) << 8);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(u, &buf) catch 1;
                out.appendSlice(arena, buf[0..n]) catch return error.OutOfMemory;
            }
            return out.items;
        },
    }
}

// ── dispatch ─────────────────────────────────────────────────────────────────

/// Dispatch a `buffer_fn` native by `name`. Statics ignore `this_val`; prototype methods use it as
/// the receiver Buffer.
pub fn bufferFn(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    // Statics + the constructor.
    if (eq(u8, name, "Buffer")) return bFrom(self, args, true);
    if (eq(u8, name, "from")) return bFrom(self, args, false);
    if (eq(u8, name, "alloc")) return bAlloc(self, args, true);
    if (eq(u8, name, "allocUnsafe") or eq(u8, name, "allocUnsafeSlow")) return bAlloc(self, args, false);
    if (eq(u8, name, "isBuffer")) return .{ .normal = .{ .boolean = isBuffer(self, if (args.len > 0) args[0] else .undefined) } };
    if (eq(u8, name, "byteLength")) return bByteLength(self, args);
    if (eq(u8, name, "concat")) return bConcat(self, args);
    // Prototype methods (receiver = this_val).
    const recv = this_val;
    if (recv != .object) return self.throwError("TypeError", "Buffer method called on non-object");
    const buf = recv.object;
    const bytes = bytesOf(buf) orelse return self.throwError("TypeError", "not a Buffer");
    if (eq(u8, name, "toString")) return bToString(self, bytes, args);
    if (eq(u8, name, "write")) return bWrite(self, bytes, args);
    if (eq(u8, name, "slice") or eq(u8, name, "subarray")) return bSlice(self, buf, bytes.len, args);
    if (eq(u8, name, "equals")) return bEquals(self, bytes, args);
    if (eq(u8, name, "toJSON")) return bToJSON(self, bytes);
    return readWrite(self, bytes, name, args);
}

fn isBuffer(self: *Interpreter, v: Value) bool {
    if (v != .object) return false;
    if (v.object.typed_array == null) return false;
    const bp = self.globalProto("Buffer") orelse return false;
    var p: ?*Object = v.object.prototype;
    while (p) |proto| : (p = proto.prototype) if (proto == bp) return true;
    return false;
}

fn toIndex(self: *Interpreter, v: Value, default: usize, max: usize) EvalError!usize {
    if (v == .undefined) return default;
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return default;
    var n = nd.normal.number;
    if (std.math.isNan(n)) n = 0;
    if (n < 0) n = 0;
    if (n > @as(f64, @floatFromInt(max))) n = @floatFromInt(max);
    return @intFromFloat(n);
}

fn argEnc(self: *Interpreter, v: Value) EvalError!Enc {
    if (v == .undefined) return .utf8;
    const sc = try self.toStringValuePub(v);
    if (sc.isAbrupt()) return .utf8;
    return parseEnc(sc.normal.string);
}

fn bAlloc(self: *Interpreter, args: []const Value, do_fill: bool) EvalError!Completion {
    const size = try toIndex(self, if (args.len > 0) args[0] else .undefined, 0, 1 << 30);
    const buf = try makeBuffer(self, size);
    if (do_fill and args.len > 1 and args[1] != .undefined) {
        const bytes = bytesOf(buf).?;
        if (args[1] == .string or args.len > 2) {
            const sc = try self.toStringValuePub(args[1]);
            if (sc.isAbrupt()) return sc;
            const enc = if (args.len > 2) try argEnc(self, args[2]) else Enc.utf8;
            const fill = try encode(self.arena, sc.normal.string, enc);
            if (fill.len > 0) {
                var i: usize = 0;
                while (i < bytes.len) : (i += 1) bytes[i] = fill[i % fill.len];
            }
        } else {
            const nd = try self.toNumberV(args[1]);
            if (nd.isAbrupt()) return nd;
            @memset(bytes, @truncate(@as(u64, @intFromFloat(@mod(@max(nd.normal.number, 0), 256)))));
        }
    }
    return .{ .normal = .{ .object = buf } };
}

fn bFrom(self: *Interpreter, args: []const Value, ctor_number_allocs: bool) EvalError!Completion {
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    switch (a0) {
        .string => |s| {
            const enc = if (args.len > 1) try argEnc(self, args[1]) else Enc.utf8;
            const bytes = try encode(self.arena, s, enc);
            return .{ .normal = .{ .object = try makeBufferFromBytes(self, bytes) } };
        },
        .number => |n| {
            // `new Buffer(n)` (deprecated) allocates n zeroed bytes; `Buffer.from(number)` is a TypeError.
            if (!ctor_number_allocs) return self.throwError("TypeError", "The \"value\" argument must not be of type number");
            const size: usize = if (std.math.isNan(n) or n < 0) 0 else @intFromFloat(@min(n, 1 << 30));
            return .{ .normal = .{ .object = try makeBuffer(self, size) } };
        },
        .object => |o| {
            // A typed array / Buffer → copy its bytes. An ArrayBuffer → a VIEW sharing it. Else an
            // array-like of byte values.
            if (bytesOf(o)) |src| return .{ .normal = .{ .object = try makeBufferFromBytes(self, src) } };
            if (o.array_buffer) |ab| {
                const off = try toIndex(self, if (args.len > 1) args[1] else .undefined, 0, ab.bytes.len);
                const len = try toIndex(self, if (args.len > 2) args[2] else .undefined, ab.bytes.len - off, ab.bytes.len - off);
                const proto = self.globalProto("Buffer") orelse self.globalProto("Uint8Array");
                const view = Object.createTypedArray(self.arena, proto, o, off, len, .u8) catch return error.OutOfMemory;
                return .{ .normal = .{ .object = view } };
            }
            // Array-like: read .length then each index as a byte.
            const lenc = try self.getProperty(a0, "length");
            if (lenc.isAbrupt()) return lenc;
            const len = try toIndex(self, lenc.normal, 0, 1 << 30);
            const buf = try makeBuffer(self, len);
            const bytes = bytesOf(buf).?;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const ec = try self.getPropertyV(a0, .{ .number = @floatFromInt(i) });
                if (ec.isAbrupt()) return ec;
                const nd = try self.toNumberV(ec.normal);
                if (nd.isAbrupt()) return nd;
                bytes[i] = @truncate(@as(u64, @intFromFloat(@mod(@max(nd.normal.number, 0), 256))));
            }
            return .{ .normal = .{ .object = buf } };
        },
        else => return self.throwError("TypeError", "The first argument must be of type string, Buffer, ArrayBuffer, Array, or Array-like"),
    }
}

fn bByteLength(self: *Interpreter, args: []const Value) EvalError!Completion {
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    if (a0 == .object) if (bytesOf(a0.object)) |bytes| return .{ .normal = .{ .number = @floatFromInt(bytes.len) } };
    const sc = try self.toStringValuePub(a0);
    if (sc.isAbrupt()) return sc;
    const enc = if (args.len > 1) try argEnc(self, args[1]) else Enc.utf8;
    const bytes = try encode(self.arena, sc.normal.string, enc);
    return .{ .normal = .{ .number = @floatFromInt(bytes.len) } };
}

fn bConcat(self: *Interpreter, args: []const Value) EvalError!Completion {
    const list: Value = if (args.len > 0) args[0] else .undefined;
    if (list != .object) return self.throwError("TypeError", "list argument must be an Array of Buffers");
    const lenc = try self.getProperty(list, "length");
    if (lenc.isAbrupt()) return lenc;
    const count = try toIndex(self, lenc.normal, 0, 1 << 30);
    // First pass: total length.
    var total: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ec = try self.getPropertyV(list, .{ .number = @floatFromInt(i) });
        if (ec.isAbrupt()) return ec;
        if (ec.normal == .object) if (bytesOf(ec.normal.object)) |b| {
            total += b.len;
        };
    }
    if (args.len > 1 and args[1] != .undefined) total = try toIndex(self, args[1], total, 1 << 30);
    const out = try makeBuffer(self, total);
    const dst = bytesOf(out).?;
    var off: usize = 0;
    i = 0;
    while (i < count and off < dst.len) : (i += 1) {
        const ec = try self.getPropertyV(list, .{ .number = @floatFromInt(i) });
        if (ec.isAbrupt()) return ec;
        if (ec.normal == .object) if (bytesOf(ec.normal.object)) |b| {
            const n = @min(b.len, dst.len - off);
            @memcpy(dst[off .. off + n], b[0..n]);
            off += n;
        };
    }
    return .{ .normal = .{ .object = out } };
}

fn bToString(self: *Interpreter, bytes: []u8, args: []const Value) EvalError!Completion {
    const enc = if (args.len > 0) try argEnc(self, args[0]) else Enc.utf8;
    const start = try toIndex(self, if (args.len > 1) args[1] else .undefined, 0, bytes.len);
    const end = try toIndex(self, if (args.len > 2) args[2] else .undefined, bytes.len, bytes.len);
    const slice = if (end > start) bytes[start..end] else bytes[0..0];
    const s = try decode(self.arena, slice, enc);
    return .{ .normal = .{ .string = s } };
}

fn bWrite(self: *Interpreter, bytes: []u8, args: []const Value) EvalError!Completion {
    const sc = try self.toStringValuePub(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    // write(string, [offset], [length], [encoding]); offset/length are optional numbers, encoding a
    // trailing string. Detect a string in slot 1 (offset omitted) → encoding.
    var offset: usize = 0;
    var max_len: usize = bytes.len;
    var enc: Enc = .utf8;
    if (args.len > 1) {
        if (args[1] == .string) {
            enc = parseEnc(args[1].string);
        } else {
            offset = try toIndex(self, args[1], 0, bytes.len);
            max_len = bytes.len - offset;
            if (args.len > 2) {
                if (args[2] == .string) enc = parseEnc(args[2].string) else {
                    max_len = @min(max_len, try toIndex(self, args[2], max_len, bytes.len));
                    if (args.len > 3) enc = try argEnc(self, args[3]);
                }
            }
        }
    }
    const enc_bytes = try encode(self.arena, sc.normal.string, enc);
    const n = @min(enc_bytes.len, max_len);
    if (offset + n <= bytes.len) @memcpy(bytes[offset .. offset + n], enc_bytes[0..n]);
    return .{ .normal = .{ .number = @floatFromInt(n) } };
}

fn bSlice(self: *Interpreter, buf: *Object, len: usize, args: []const Value) EvalError!Completion {
    // Node `slice`/`subarray` SHARE the underlying ArrayBuffer (a new view, not a copy).
    var start = try relIndex(self, if (args.len > 0) args[0] else .undefined, 0, len);
    var end = try relIndex(self, if (args.len > 1) args[1] else .undefined, len, len);
    if (end < start) end = start;
    const ta = buf.typed_array.?;
    const new_len = end - start;
    const proto = self.globalProto("Buffer") orelse self.globalProto("Uint8Array");
    const view = Object.createTypedArray(self.arena, proto, ta.buffer, ta.byte_offset + start, new_len, .u8) catch return error.OutOfMemory;
    _ = &start;
    return .{ .normal = .{ .object = view } };
}

/// Resolve a Node slice index: negative counts from the end; clamp to [0, len].
fn relIndex(self: *Interpreter, v: Value, default: usize, len: usize) EvalError!usize {
    if (v == .undefined) return default;
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return default;
    var n = nd.normal.number;
    if (std.math.isNan(n)) return 0;
    if (n < 0) n += @floatFromInt(len);
    if (n < 0) n = 0;
    if (n > @as(f64, @floatFromInt(len))) n = @floatFromInt(len);
    return @intFromFloat(n);
}

fn bEquals(self: *Interpreter, bytes: []u8, args: []const Value) EvalError!Completion {
    const other: Value = if (args.len > 0) args[0] else .undefined;
    if (other != .object) return self.throwError("TypeError", "argument must be a Buffer or Uint8Array");
    const ob = bytesOf(other.object) orelse return self.throwError("TypeError", "argument must be a Buffer or Uint8Array");
    return .{ .normal = .{ .boolean = std.mem.eql(u8, bytes, ob) } };
}

fn bToJSON(self: *Interpreter, bytes: []u8) EvalError!Completion {
    const obj = Object.create(self.arena, self.globalProto("Object")) catch return error.OutOfMemory;
    try obj.defineData("type", .{ .string = "Buffer" }, true, true, true);
    const arr = Object.createArray(self.arena, self.arrayProto()) catch return error.OutOfMemory;
    for (bytes, 0..) |b, i| try arr.arraySet(self.arena, i, .{ .number = @floatFromInt(b) });
    try obj.defineData("data", .{ .object = arr }, true, true, true);
    return .{ .normal = .{ .object = obj } };
}

/// The small read/write numeric matrix (UInt8 / UInt16LE/BE / UInt32LE/BE).
fn readWrite(self: *Interpreter, bytes: []u8, name: []const u8, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    const off = try toIndex(self, if (args.len > 0 and !std.mem.startsWith(u8, name, "write")) args[0] else (if (args.len > 1) args[1] else .undefined), 0, bytes.len);
    if (std.mem.startsWith(u8, name, "read")) {
        const ro = try toIndex(self, if (args.len > 0) args[0] else .undefined, 0, bytes.len);
        if (eq(u8, name, "readUInt8")) {
            if (ro >= bytes.len) return self.throwError("RangeError", "out of range");
            return .{ .normal = .{ .number = @floatFromInt(bytes[ro]) } };
        }
        if (eq(u8, name, "readUInt16LE") or eq(u8, name, "readUInt16BE")) {
            if (ro + 2 > bytes.len) return self.throwError("RangeError", "out of range");
            const le = eq(u8, name, "readUInt16LE");
            const v: u16 = if (le) @as(u16, bytes[ro]) | (@as(u16, bytes[ro + 1]) << 8) else (@as(u16, bytes[ro]) << 8) | @as(u16, bytes[ro + 1]);
            return .{ .normal = .{ .number = @floatFromInt(v) } };
        }
        if (eq(u8, name, "readUInt32LE") or eq(u8, name, "readUInt32BE")) {
            if (ro + 4 > bytes.len) return self.throwError("RangeError", "out of range");
            const le = eq(u8, name, "readUInt32LE");
            var v: u32 = 0;
            if (le) {
                inline for (0..4) |k| v |= @as(u32, bytes[ro + k]) << (8 * k);
            } else {
                inline for (0..4) |k| v = (v << 8) | @as(u32, bytes[ro + k]);
            }
            return .{ .normal = .{ .number = @floatFromInt(v) } };
        }
        return .{ .normal = .undefined };
    }
    // write*: value is arg[0], offset arg[1].
    const nd = try self.toNumberV(if (args.len > 0) args[0] else .undefined);
    if (nd.isAbrupt()) return nd;
    const val: u64 = @intFromFloat(@mod(@max(nd.normal.number, 0), 4294967296.0));
    if (eq(u8, name, "writeUInt8")) {
        if (off >= bytes.len) return self.throwError("RangeError", "out of range");
        bytes[off] = @truncate(val);
        return .{ .normal = .{ .number = @floatFromInt(off + 1) } };
    }
    if (eq(u8, name, "writeUInt16LE") or eq(u8, name, "writeUInt16BE")) {
        if (off + 2 > bytes.len) return self.throwError("RangeError", "out of range");
        const v: u16 = @truncate(val);
        if (eq(u8, name, "writeUInt16LE")) {
            bytes[off] = @truncate(v);
            bytes[off + 1] = @truncate(v >> 8);
        } else {
            bytes[off] = @truncate(v >> 8);
            bytes[off + 1] = @truncate(v);
        }
        return .{ .normal = .{ .number = @floatFromInt(off + 2) } };
    }
    if (eq(u8, name, "writeUInt32LE") or eq(u8, name, "writeUInt32BE")) {
        if (off + 4 > bytes.len) return self.throwError("RangeError", "out of range");
        const v: u32 = @truncate(val);
        if (eq(u8, name, "writeUInt32LE")) {
            inline for (0..4) |k| bytes[off + k] = @truncate(v >> (8 * k));
        } else {
            inline for (0..4) |k| bytes[off + k] = @truncate(v >> (8 * (3 - k)));
        }
        return .{ .normal = .{ .number = @floatFromInt(off + 4) } };
    }
    return .{ .normal = .undefined };
}
