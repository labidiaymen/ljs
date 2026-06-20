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
const rw = @import("host_buffer_rw.zig");

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
    for ([_][]const u8{ "alloc", "allocUnsafe", "allocUnsafeSlow", "from", "isBuffer", "byteLength", "concat", "compare", "isEncoding", "of" }) |name|
        try defineMethod(self, ctor, name, function_proto);
    // Prototype methods.
    for ([_][]const u8{
        "toString",        "write",           "slice",            "subarray",         "equals",          "toJSON",
        "indexOf",         "lastIndexOf",     "includes",         "fill",             "copy",            "compare",
        "swap16",          "swap32",
        // Numeric read/write matrix (dispatched via host_buffer_rw.zig).
                 "readInt8",         "readUInt8",        "writeInt8",       "writeUInt8",
        "readInt16LE",     "readInt16BE",     "readUInt16LE",     "readUInt16BE",     "writeInt16LE",    "writeInt16BE",
        "writeUInt16LE",   "writeUInt16BE",   "readInt32LE",      "readInt32BE",      "readUInt32LE",    "readUInt32BE",
        "writeInt32LE",    "writeInt32BE",    "writeUInt32LE",    "writeUInt32BE",    "readFloatLE",     "readFloatBE",
        "writeFloatLE",    "writeFloatBE",    "readDoubleLE",     "readDoubleBE",     "writeDoubleLE",   "writeDoubleBE",
        // Variable-width (byteLength 1–6) integer accessors.
        "readIntLE",       "readIntBE",       "readUIntLE",       "readUIntBE",       "writeIntLE",      "writeIntBE",
        "writeUIntLE",     "writeUIntBE",
        // BigInt 64-bit accessors.
            "readBigInt64LE",   "readBigInt64BE",   "readBigUInt64LE", "readBigUInt64BE",
        "writeBigInt64LE", "writeBigInt64BE", "writeBigUInt64LE", "writeBigUInt64BE", "swap64",
    }) |name|
        try defineMethod(self, proto, name, function_proto);

    try env.declare("Buffer", .{ .object = ctor }, true, true);
    if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object)
        try gb.value.object.defineData("Buffer", .{ .object = ctor }, true, false, true);
}

/// Create a standalone `buffer_fn` native function named `name` (for the `buffer` module's
/// `SlowBuffer` export). Dispatched through `bufferFn` by `name`.
pub fn makeNative(self: *Interpreter, name: []const u8) EvalError!*Object {
    const fn_obj = try Object.createNative(self.arena, .buffer_fn, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    return fn_obj;
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
    return parseEncOpt(name) orelse .utf8;
}

/// Like `parseEnc` but returns null for an unrecognized encoding name (so callers can throw
/// `ERR_UNKNOWN_ENCODING` where Node does).
fn parseEncOpt(name: []const u8) ?Enc {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "utf8") or eq(name, "utf-8")) return .utf8;
    if (eq(name, "hex")) return .hex;
    if (eq(name, "base64") or eq(name, "base64url")) return .base64;
    if (eq(name, "latin1") or eq(name, "binary")) return .latin1;
    if (eq(name, "ascii")) return .ascii;
    if (eq(name, "utf16le") or eq(name, "ucs2") or eq(name, "ucs-2") or eq(name, "utf-16le")) return .utf16le;
    return null;
}

/// Resolve an encoding argument, THROWING `ERR_UNKNOWN_ENCODING` (TypeError) for an unrecognized
/// name (Node's `toString`/`write` behavior). `undefined` → utf8. Returns the Enc or a throw.
fn argEncChecked(self: *Interpreter, v: Value) EvalError!union(enum) { enc: Enc, throw: Completion } {
    if (v == .undefined) return .{ .enc = .utf8 };
    const sc = try self.toStringValuePub(v);
    if (sc.isAbrupt()) return .{ .throw = sc };
    if (parseEncOpt(sc.normal.string)) |e| return .{ .enc = e };
    const msg = std.fmt.allocPrint(self.arena, "Unknown encoding: {s}", .{sc.normal.string}) catch return error.OutOfMemory;
    return .{ .throw = try throwCode(self, "TypeError", "ERR_UNKNOWN_ENCODING", msg) };
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
    if (eq(u8, name, "SlowBuffer")) {
        // SlowBuffer(size) requires a number-typed size (TypeError otherwise), then allocs zeroed.
        const a0: Value = if (args.len > 0) args[0] else .undefined;
        if (a0 != .number)
            return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"size\" argument must be of type number.");
        return bAlloc(self, args, true);
    }
    if (eq(u8, name, "isBuffer")) return .{ .normal = .{ .boolean = isBuffer(self, if (args.len > 0) args[0] else .undefined) } };
    if (eq(u8, name, "byteLength")) return bByteLength(self, args);
    if (eq(u8, name, "concat")) return bConcat(self, args);
    if (eq(u8, name, "isEncoding")) return .{ .normal = .{ .boolean = isEncoding(self, if (args.len > 0) args[0] else .undefined) } };
    if (eq(u8, name, "of")) return bOf(self, args);
    if (eq(u8, name, "isAscii") or eq(u8, name, "isUtf8")) return bIsAsciiUtf8(self, eq(u8, name, "isAscii"), args);
    // `Buffer.compare(a, b)` static vs `buf.compare(other)` prototype: the static form has a non-Buffer
    // `this_val` (the `Buffer` ctor) and reads both operands from args.
    if (eq(u8, name, "compare") and !(this_val == .object and bytesOf(this_val.object) != null))
        return bCompareStatic(self, args);
    // Prototype methods (receiver = this_val). A non-Buffer receiver is an ERR_INVALID_ARG_TYPE
    // (Node validates `this`/`source` as a Buffer or Uint8Array).
    const recv = this_val;
    const src_exp = "an instance of Buffer or Uint8Array";
    if (recv != .object) return throwArgType(self, "source", src_exp, recv);
    const buf = recv.object;
    const bytes = bytesOf(buf) orelse return throwArgType(self, "source", src_exp, recv);
    if (eq(u8, name, "toString")) return bToString(self, bytes, args);
    if (eq(u8, name, "write")) return bWrite(self, bytes, args);
    if (eq(u8, name, "slice") or eq(u8, name, "subarray")) return bSlice(self, buf, bytes.len, args);
    if (eq(u8, name, "equals")) return bEquals(self, bytes, args);
    if (eq(u8, name, "toJSON")) return bToJSON(self, bytes);
    if (eq(u8, name, "indexOf")) return bIndexOf(self, bytes, args, .first);
    if (eq(u8, name, "lastIndexOf")) return bIndexOf(self, bytes, args, .last);
    if (eq(u8, name, "includes")) return bIndexOf(self, bytes, args, .includes);
    if (eq(u8, name, "fill")) return bFill(self, buf, bytes, args);
    if (eq(u8, name, "copy")) return bCopy(self, bytes, args);
    if (eq(u8, name, "compare")) return bCompare(self, bytes, args);
    if (eq(u8, name, "swap16")) return bSwap(self, buf, bytes, 2);
    if (eq(u8, name, "swap32")) return bSwap(self, buf, bytes, 4);
    if (eq(u8, name, "swap64")) return bSwap(self, buf, bytes, 8);
    if (try rw.readWrite(self, bytes, name, args)) |c| return c;
    return .{ .normal = .undefined };
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

/// Clamp a finite/Infinity/NaN f64 to the i64 range so `@intFromFloat` can never panic. NaN → 0.
fn clampToI64(n: f64) i64 {
    if (std.math.isNan(n)) return 0;
    if (n >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (n <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @intFromFloat(n);
}

/// Throw a Node-style error (RangeError/TypeError) carrying a `code` property (e.g.
/// "ERR_OUT_OF_RANGE"), which the Node tests' `assert.throws({ code })` validators check.
fn throwCode(self: *Interpreter, kind: []const u8, code: []const u8, msg: []const u8) EvalError!Completion {
    const arena = self.arena;
    const err = try Object.create(arena, self.errorProto(kind));
    err.error_data = true;
    try err.set("name", .{ .string = kind });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = code }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Node's `Received <detail>` suffix for an ERR_INVALID_ARG_TYPE message, describing the actual
/// value's type (e.g. `type string ('abc')`, `type number (5)`, `an instance of Foo`, `null`).
fn receivedDetail(self: *Interpreter, v: Value) EvalError![]const u8 {
    const arena = self.arena;
    const ao = @import("abstract_ops.zig");
    return switch (v) {
        .undefined => "undefined",
        .null => "null",
        .boolean => |b| std.fmt.allocPrint(arena, "type boolean ({s})", .{if (b) "true" else "false"}) catch return error.OutOfMemory,
        .number => |n| blk: {
            const s = ao.numberToString(arena, n) catch return error.OutOfMemory;
            break :blk std.fmt.allocPrint(arena, "type number ({s})", .{s}) catch return error.OutOfMemory;
        },
        .string => |s| std.fmt.allocPrint(arena, "type string ('{s}')", .{s}) catch return error.OutOfMemory,
        .bigint => "type bigint",
        .symbol => "type symbol",
        .object => |o| if (o.kind == .function) "function" else "an instance of Object",
    };
}

/// Throw ERR_INVALID_ARG_TYPE (TypeError) with Node's full "must be ... Received ..." message.
fn throwArgType(self: *Interpreter, arg_name: []const u8, expected: []const u8, v: Value) EvalError!Completion {
    const detail = try receivedDetail(self, v);
    const msg = std.fmt.allocPrint(self.arena, "The \"{s}\" argument must be {s}. Received {s}", .{ arg_name, expected, detail }) catch return error.OutOfMemory;
    return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg);
}

/// Validate an allocation/length size argument: must be a non-negative integer ≤ kMaxLength.
/// Returns the size, or throws (ERR_OUT_OF_RANGE / ERR_INVALID_ARG_TYPE) like Node.
fn validateSize(self: *Interpreter, v: Value) EvalError!union(enum) { size: usize, throw: Completion } {
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return .{ .throw = nd };
    const n = nd.normal.number;
    if (std.math.isNan(n) or n != @trunc(n))
        return .{ .throw = try throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", "The value of \"size\" is out of range. It must be an integer.") };
    if (n < 0 or n > @as(f64, @floatFromInt(kMaxLength)))
        return .{ .throw = try throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", "The value of \"size\" is out of range.") };
    return .{ .size = @intFromFloat(n) };
}

/// Node's `buffer.kMaxLength` (max bytes in a Buffer). We cap allocation at a sane ceiling well below
/// this so a huge-but-valid size throws rather than OOMs.
pub const kMaxLength: u64 = 4294967295;
/// Practical allocation ceiling: a request above this throws ERR_OUT_OF_RANGE instead of OOMing.
const ALLOC_CAP: u64 = 1 << 30;

fn bAlloc(self: *Interpreter, args: []const Value, do_fill: bool) EvalError!Completion {
    const vs = try validateSize(self, if (args.len > 0) args[0] else .{ .number = 0 });
    const size = switch (vs) {
        .throw => |c| return c,
        .size => |s| s,
    };
    if (size > ALLOC_CAP)
        return throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", "The value of \"size\" is out of range.");
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
        .number => {
            // `new Buffer(n)` (deprecated) allocates n zeroed bytes; `Buffer.from(number)` is a TypeError.
            if (!ctor_number_allocs)
                return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"value\" argument must not be of type number");
            const vs = try validateSize(self, a0);
            const size = switch (vs) {
                .throw => |c| return c,
                .size => |s| s,
            };
            if (size > ALLOC_CAP)
                return throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", "The value of \"size\" is out of range.");
            return .{ .normal = .{ .object = try makeBuffer(self, size) } };
        },
        .undefined, .null, .boolean => return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The first argument must be of type string or an instance of Buffer, ArrayBuffer, Array, or Array-like Object."),
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
        else => return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The first argument must be of type string or an instance of Buffer, ArrayBuffer, Array, or Array-like Object."),
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
    const enc = switch (try argEncChecked(self, if (args.len > 0) args[0] else .undefined)) {
        .enc => |e| e,
        .throw => |c| return c,
    };
    const start = try toIndex(self, if (args.len > 1) args[1] else .undefined, 0, bytes.len);
    const end = try toIndex(self, if (args.len > 2) args[2] else .undefined, bytes.len, bytes.len);
    const slice = if (end > start) bytes[start..end] else bytes[0..0];
    const s = try decode(self.arena, slice, enc);
    return .{ .normal = .{ .string = s } };
}

/// Validate `buf.write`'s offset: an integer in [0, len]; else ERR_OUT_OF_RANGE with Node's `&&`
/// bounds message. `undefined` → 0.
fn writeOffset(self: *Interpreter, v: Value, len: usize) EvalError!union(enum) { v: usize, throw: Completion } {
    if (v == .undefined) return .{ .v = 0 };
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return .{ .throw = nd };
    const n = nd.normal.number;
    if (std.math.isNan(n) or n != @trunc(n) or n < 0 or n > @as(f64, @floatFromInt(len))) {
        const ao = @import("abstract_ops.zig");
        const recv = ao.numberToString(self.arena, n) catch return error.OutOfMemory;
        const msg = std.fmt.allocPrint(self.arena, "The value of \"offset\" is out of range. It must be >= 0 && <= {d}. Received {s}", .{ len, recv }) catch return error.OutOfMemory;
        return .{ .throw = try throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", msg) };
    }
    return .{ .v = @intFromFloat(n) };
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
            enc = switch (try argEncChecked(self, args[1])) {
                .enc => |e| e,
                .throw => |c| return c,
            };
        } else {
            // offset must be an integer in [0, len] (Node throws ERR_OUT_OF_RANGE with `&&` bounds).
            offset = switch (try writeOffset(self, args[1], bytes.len)) {
                .v => |o| o,
                .throw => |c| return c,
            };
            max_len = bytes.len - offset;
            if (args.len > 2) {
                if (args[2] == .string) {
                    enc = switch (try argEncChecked(self, args[2])) {
                        .enc => |e| e,
                        .throw => |c| return c,
                    };
                } else {
                    max_len = @min(max_len, try toIndex(self, args[2], max_len, bytes.len));
                    if (args.len > 3) {
                        enc = switch (try argEncChecked(self, args[3])) {
                            .enc => |e| e,
                            .throw => |c| return c,
                        };
                    }
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
    const exp = "an instance of Buffer or Uint8Array";
    if (other != .object) return throwArgType(self, "otherBuffer", exp, other);
    const ob = bytesOf(other.object) orelse return throwArgType(self, "otherBuffer", exp, other);
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

// ── search / fill / copy / compare / swap ────────────────────────────────────

/// Resolve a search "needle" argument to a byte sequence: a number → a single byte; a string →
/// encoded bytes; a Buffer/Uint8Array → its bytes. Returns null for an unsupported value.
fn needleBytes(self: *Interpreter, v: Value, enc: Enc) EvalError!?[]const u8 {
    switch (v) {
        .number => |n| {
            const b: u8 = @truncate(@as(u64, @intFromFloat(@mod(@max(@trunc(n), 0), 256))));
            const out = self.arena.alloc(u8, 1) catch return error.OutOfMemory;
            out[0] = b;
            return out;
        },
        .string => |s| return try encode(self.arena, s, enc),
        .object => |o| return bytesOf(o),
        else => return null,
    }
}

const SearchKind = enum { first, last, includes };

fn bIndexOf(self: *Interpreter, bytes: []u8, args: []const Value, kind: SearchKind) EvalError!Completion {
    const val: Value = if (args.len > 0) args[0] else .undefined;
    // Trailing encoding arg: indexOf(value[, byteOffset[, encoding]]).
    const enc: Enc = if (args.len > 2) try argEnc(self, args[2]) else (if (args.len > 1 and args[1] == .string) try argEnc(self, args[1]) else Enc.utf8);
    const needle = (try needleBytes(self, val, enc)) orelse return notFound(kind, bytes.len);

    // byteOffset (only when args[1] is not the encoding string).
    const has_off = args.len > 1 and args[1] != .string;
    var start: i64 = if (kind == .last) @as(i64, @intCast(bytes.len)) else 0;
    if (has_off) {
        const nd = try self.toNumberV(args[1]);
        if (nd.isAbrupt()) return nd;
        var n = nd.normal.number;
        if (std.math.isNan(n)) n = if (kind == .last) @floatFromInt(bytes.len) else 0;
        n = @trunc(n);
        if (n < 0) n += @floatFromInt(bytes.len);
        start = clampToI64(n);
    }

    if (needle.len == 0) {
        // Empty needle: Node returns clamped offset (or length).
        var s = start;
        if (s < 0) s = 0;
        if (s > @as(i64, @intCast(bytes.len))) s = @intCast(bytes.len);
        return found(kind, @intCast(s), bytes.len);
    }

    if (kind == .last) {
        // Search backwards; start is the highest index the match may BEGIN at.
        if (start < 0) return notFound(kind, bytes.len);
        var i: i64 = @min(start, @as(i64, @intCast(bytes.len)) - @as(i64, @intCast(needle.len)));
        while (i >= 0) : (i -= 1) {
            const u: usize = @intCast(i);
            if (std.mem.eql(u8, bytes[u .. u + needle.len], needle)) return found(kind, u, bytes.len);
        }
        return notFound(kind, bytes.len);
    }
    // first / includes: forward.
    var s = start;
    if (s < 0) s = 0;
    var i: usize = @intCast(s);
    while (i + needle.len <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + needle.len], needle)) return found(kind, i, bytes.len);
    }
    return notFound(kind, bytes.len);
}

fn found(kind: SearchKind, idx: usize, len: usize) Completion {
    _ = len;
    if (kind == .includes) return .{ .normal = .{ .boolean = true } };
    return .{ .normal = .{ .number = @floatFromInt(idx) } };
}

fn notFound(kind: SearchKind, len: usize) Completion {
    _ = len;
    if (kind == .includes) return .{ .normal = .{ .boolean = false } };
    return .{ .normal = .{ .number = -1 } };
}

/// fill(value[, start[, end]][, encoding]). Mutates and returns the buffer.
fn bFill(self: *Interpreter, buf: *Object, bytes: []u8, args: []const Value) EvalError!Completion {
    const val: Value = if (args.len > 0) args[0] else .undefined;
    // Optional trailing encoding string (in slot 1, 2, or 3).
    var enc: Enc = .utf8;
    var n_numeric: usize = args.len; // count of args excluding a trailing encoding string
    if (args.len > 1 and args[args.len - 1] == .string and val != .string) {
        // Only treat the last arg as encoding if value is non-string (string value + 1 arg is ambiguous;
        // Node treats fill(str) start/end numeric). Conservative: trailing string = encoding.
        enc = try argEnc(self, args[args.len - 1]);
        n_numeric = args.len - 1;
    } else if (val == .string and args.len >= 2 and args[args.len - 1] == .string) {
        enc = try argEnc(self, args[args.len - 1]);
        n_numeric = args.len - 1;
    }
    const start = try toIndex(self, if (n_numeric > 1) args[1] else .undefined, 0, bytes.len);
    const end = try toIndex(self, if (n_numeric > 2) args[2] else .undefined, bytes.len, bytes.len);
    if (end <= start) return .{ .normal = .{ .object = buf } };
    const region = bytes[start..end];
    switch (val) {
        .string => {
            const filler = try encode(self.arena, val.string, enc);
            if (filler.len == 0) {
                @memset(region, 0);
            } else {
                var i: usize = 0;
                while (i < region.len) : (i += 1) region[i] = filler[i % filler.len];
            }
        },
        else => {
            const nd = try self.toNumberV(val);
            if (nd.isAbrupt()) return nd;
            const b: u8 = @truncate(@as(u64, @intFromFloat(@mod(@max(@trunc(nd.normal.number), 0), 256))));
            @memset(region, b);
        },
    }
    return .{ .normal = .{ .object = buf } };
}

/// Resolve a `copy` index arg: ToInteger, must be `>= 0` (ERR_OUT_OF_RANGE `It must be >= 0`).
/// When `cap_throws`, a value `> max` also throws `>= 0 && <= {max}`; otherwise it is returned as-is
/// (the caller clamps). `undefined` → `default`. A non-integer coerces (Node coerces copy offsets).
fn copyIndex(self: *Interpreter, v: Value, default: usize, max: usize, cap_throws: bool, name: []const u8) EvalError!union(enum) { v: usize, throw: Completion } {
    if (v == .undefined) return .{ .v = default };
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return .{ .throw = nd };
    var n = nd.normal.number;
    if (std.math.isNan(n)) n = 0;
    n = @trunc(n);
    const ao = @import("abstract_ops.zig");
    if (n < 0) {
        const recv = ao.numberToString(self.arena, nd.normal.number) catch return error.OutOfMemory;
        const msg = std.fmt.allocPrint(self.arena, "The value of \"{s}\" is out of range. It must be >= 0. Received {s}", .{ name, recv }) catch return error.OutOfMemory;
        return .{ .throw = try throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", msg) };
    }
    if (cap_throws and n > @as(f64, @floatFromInt(max))) {
        const recv = ao.numberToString(self.arena, nd.normal.number) catch return error.OutOfMemory;
        const msg = std.fmt.allocPrint(self.arena, "The value of \"{s}\" is out of range. It must be >= 0 && <= {d}. Received {s}", .{ name, max, recv }) catch return error.OutOfMemory;
        return .{ .throw = try throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", msg) };
    }
    return .{ .v = @intFromFloat(n) };
}

/// copy(target[, targetStart[, sourceStart[, sourceEnd]]]). Returns the number of bytes copied.
fn bCopy(self: *Interpreter, bytes: []u8, args: []const Value) EvalError!Completion {
    const target: Value = if (args.len > 0) args[0] else .undefined;
    const exp = "an instance of Buffer or Uint8Array";
    if (target != .object) return throwArgType(self, "target", exp, target);
    const dst = bytesOf(target.object) orelse return throwArgType(self, "target", exp, target);
    // targetStart/sourceStart/sourceEnd are coerced ToInteger then range-checked (>= 0, and source
    // offsets <= source length); Node throws ERR_OUT_OF_RANGE on a negative / too-large value.
    const t_start = switch (try copyIndex(self, if (args.len > 1) args[1] else .undefined, 0, dst.len, false, "targetStart")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    const s_start = switch (try copyIndex(self, if (args.len > 2) args[2] else .undefined, 0, bytes.len, true, "sourceStart")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    var s_end = switch (try copyIndex(self, if (args.len > 3) args[3] else .undefined, bytes.len, bytes.len, false, "sourceEnd")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    if (s_end > bytes.len) s_end = bytes.len;
    if (s_end <= s_start or t_start >= dst.len) return .{ .normal = .{ .number = 0 } };
    const n = @min(s_end - s_start, dst.len - t_start);
    // Source and target may overlap (same backing ArrayBuffer); use a forward/backward safe move.
    std.mem.copyForwards(u8, dst[t_start .. t_start + n], bytes[s_start .. s_start + n]);
    return .{ .normal = .{ .number = @floatFromInt(n) } };
}

/// Lexicographic byte comparison → -1 / 0 / 1.
fn cmpBytes(a: []const u8, b: []const u8) f64 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// `buf.compare(target[, targetStart[, targetEnd[, sourceStart[, sourceEnd]]]])`. The optional
/// range args slice both operands before the lexicographic comparison; each must be an integer in
/// the valid range (ERR_INVALID_ARG_TYPE / ERR_OUT_OF_RANGE otherwise).
fn bCompare(self: *Interpreter, bytes: []u8, args: []const Value) EvalError!Completion {
    const other: Value = if (args.len > 0) args[0] else .undefined;
    const exp = "an instance of Buffer or Uint8Array";
    if (other != .object) return throwArgType(self, "target", exp, other);
    const ob = bytesOf(other.object) orelse return throwArgType(self, "target", exp, other);
    // *Start args validate against kMaxLength (clamped later); *End args against the buffer length.
    const t_start = switch (try cmpRange(self, if (args.len > 1) args[1] else .undefined, 0, kMaxLength, "targetStart")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    const t_end = switch (try cmpRange(self, if (args.len > 2) args[2] else .undefined, ob.len, ob.len, "targetEnd")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    const s_start = switch (try cmpRange(self, if (args.len > 3) args[3] else .undefined, 0, kMaxLength, "sourceStart")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    const s_end = switch (try cmpRange(self, if (args.len > 4) args[4] else .undefined, bytes.len, bytes.len, "sourceEnd")) {
        .v => |x| x,
        .throw => |c| return c,
    };
    // Clamp slice indices to the actual byte lengths (the validated offsets may exceed them).
    const ss = @min(s_start, bytes.len);
    const se = @min(s_end, bytes.len);
    const ts = @min(t_start, ob.len);
    const te = @min(t_end, ob.len);
    const src = if (se > ss) bytes[ss..se] else bytes[0..0];
    const tgt = if (te > ts) ob[ts..te] else ob[0..0];
    return .{ .normal = .{ .number = cmpBytes(src, tgt) } };
}

/// Resolve one of `compare`'s optional range args: a number-typed integer in [0, kMaxLength], with
/// `undefined` → `default`. Non-number → ERR_INVALID_ARG_TYPE; out-of-range → ERR_OUT_OF_RANGE.
/// (The value is range-validated here but clamped to the actual buffer length by the caller.)
fn cmpRange(self: *Interpreter, v: Value, default: usize, max: u64, name: []const u8) EvalError!union(enum) { v: usize, throw: Completion } {
    if (v == .undefined) return .{ .v = default };
    if (v != .number) {
        const msg = std.fmt.allocPrint(self.arena, "The \"{s}\" argument must be of type number.", .{name}) catch return error.OutOfMemory;
        return .{ .throw = try throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", msg) };
    }
    const n = v.number;
    if (std.math.isNan(n) or n != @trunc(n) or n < 0 or n > @as(f64, @floatFromInt(max))) {
        const ao = @import("abstract_ops.zig");
        const recv = ao.numberToString(self.arena, n) catch return error.OutOfMemory;
        const msg = std.fmt.allocPrint(self.arena, "The value of \"{s}\" is out of range. It must be >= 0 && <= {d}. Received {s}", .{ name, max, recv }) catch return error.OutOfMemory;
        return .{ .throw = try throwCode(self, "RangeError", "ERR_OUT_OF_RANGE", msg) };
    }
    return .{ .v = @intFromFloat(n) };
}

/// Static `Buffer.compare(a, b)`.
fn bCompareStatic(self: *Interpreter, args: []const Value) EvalError!Completion {
    const a: Value = if (args.len > 0) args[0] else .undefined;
    const b: Value = if (args.len > 1) args[1] else .undefined;
    const exp = "an instance of Buffer or Uint8Array";
    const ab = (if (a == .object) bytesOf(a.object) else null) orelse return throwArgType(self, "buf1", exp, a);
    const bb = (if (b == .object) bytesOf(b.object) else null) orelse return throwArgType(self, "buf2", exp, b);
    return .{ .normal = .{ .number = cmpBytes(ab, bb) } };
}

/// swap16 / swap32 / swap64: reverse bytes within each `group`-byte chunk in place. Returns the buffer.
fn bSwap(self: *Interpreter, buf: *Object, bytes: []u8, group: usize) EvalError!Completion {
    if (bytes.len % group != 0) {
        const msg = switch (group) {
            2 => "Buffer size must be a multiple of 16-bits",
            4 => "Buffer size must be a multiple of 32-bits",
            else => "Buffer size must be a multiple of 64-bits",
        };
        return throwCode(self, "RangeError", "ERR_INVALID_BUFFER_SIZE", msg);
    }
    var i: usize = 0;
    while (i < bytes.len) : (i += group) std.mem.reverse(u8, bytes[i .. i + group]);
    return .{ .normal = .{ .object = buf } };
}

/// `Buffer.isEncoding(enc)` — true if `enc` is a recognized encoding name.
fn isEncoding(self: *Interpreter, v: Value) bool {
    _ = self;
    if (v != .string) return false;
    const s = v.string;
    const eq = std.ascii.eqlIgnoreCase;
    for ([_][]const u8{ "utf8", "utf-8", "hex", "base64", "base64url", "latin1", "binary", "ascii", "utf16le", "ucs2", "ucs-2", "utf-16le" }) |name|
        if (eq(s, name)) return true;
    return false;
}

/// `buffer.isAscii(view)` / `buffer.isUtf8(view)` — true if the view's bytes are all-ASCII / valid
/// UTF-8. The argument must be a TypedArray/Buffer or ArrayBuffer (ERR_INVALID_ARG_TYPE otherwise).
fn bIsAsciiUtf8(self: *Interpreter, ascii: bool, args: []const Value) EvalError!Completion {
    const a0: Value = if (args.len > 0) args[0] else .undefined;
    if (a0 != .object) return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"input\" argument must be an instance of Buffer, TypedArray, or ArrayBuffer.");
    const bytes: []const u8 = bytesOf(a0.object) orelse (if (a0.object.array_buffer) |ab| ab.bytes else return throwCode(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"input\" argument must be an instance of Buffer, TypedArray, or ArrayBuffer."));
    if (ascii) {
        for (bytes) |b| if (b > 0x7f) return .{ .normal = .{ .boolean = false } };
        return .{ .normal = .{ .boolean = true } };
    }
    return .{ .normal = .{ .boolean = std.unicode.utf8ValidateSlice(bytes) } };
}

/// `Buffer.of(...bytes)` — a Buffer from the argument list (each ToNumber → a byte).
fn bOf(self: *Interpreter, args: []const Value) EvalError!Completion {
    const buf = try makeBuffer(self, args.len);
    const bytes = bytesOf(buf).?;
    for (args, 0..) |a, i| {
        const nd = try self.toNumberV(a);
        if (nd.isAbrupt()) return nd;
        bytes[i] = @truncate(@as(u64, @intFromFloat(@mod(@max(@trunc(nd.normal.number), 0), 256))));
    }
    return .{ .normal = .{ .object = buf } };
}
