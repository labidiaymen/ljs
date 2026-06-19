//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const builtin_array = @import("builtin_array.zig");
const builtin_array_static = @import("builtin_array_static.zig");
const builtin_string = @import("builtin_string.zig");
const builtin_collection = @import("builtin_collection.zig");
const builtin_json = @import("builtin_json.zig");
const builtin_math = @import("builtin_math.zig");
const builtin_number = @import("builtin_number.zig");
const builtin_symbol = @import("builtin_symbol.zig");
const builtin_iterator = @import("builtin_iterator.zig");
const builtin_object = @import("builtin_object.zig");
const builtin_reflect = @import("builtin_reflect.zig");
const builtin_bigint = @import("builtin_bigint.zig");
const builtin_proxy = @import("builtin_proxy.zig");
const builtin_regexp = @import("builtin_regexp.zig");
const builtin_arraybuffer = @import("builtin_arraybuffer.zig");
const builtin_typedarray = @import("builtin_typedarray.zig");
const builtin_dataview = @import("builtin_dataview.zig");
const builtin_date = @import("builtin_date.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_expr = @import("interp_expr.zig");
const interp_async = @import("interp_async.zig");
const interp_collection = @import("interp_collection.zig");

const toBoolean = ops.toBoolean;
const numberToString = ops.numberToString;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const UriKind = Interpreter.UriKind;

fn trimLeadingWhiteSpace(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            if (!isStrWhiteSpaceByte(c)) break;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch break;
        if (i + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch break;
        if (!isUnicodeWhiteSpaceCp(cp)) break;
        i += len;
    }
    return i;
}

fn isStrWhiteSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isUnicodeWhiteSpaceCp(cp: u21) bool {
    return switch (cp) {
        0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn digitValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'z') return c - 'a' + 10;
    if (c >= 'A' and c <= 'Z') return c - 'A' + 10;
    return null;
}

fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn decodeHexByte(s: []const u8, at: usize) ?u8 {
    if (at + 2 >= s.len or s[at] != '%') return null;
    const hi = hexValue(s[at + 1]) orelse return null;
    const lo = hexValue(s[at + 2]) orelse return null;
    return hi * 16 + lo;
}

fn appendPercent(arena: std.mem.Allocator, out: *std.ArrayList(u8), b: u8) std.mem.Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    try out.append(arena, '%');
    try out.append(arena, hex[b >> 4]);
    try out.append(arena, hex[b & 0x0F]);
}

fn isUriReserved(c: u8) bool {
    return switch (c) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

fn isUriPreserved(c: u8, kind: Interpreter.UriKind) bool {
    const unescaped = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
        switch (c) {
            '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
            else => false,
        };
    if (unescaped) return true;
    if (kind == .uri) return isUriReserved(c);
    return false;
}

/// §19.2 dispatch the global functions by name (the `global_fn` native).
pub fn globalFn(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    const arg0: Value = if (args.len > 0) args[0] else .undefined;
    if (std.mem.eql(u8, name, "isNaN")) {
        // §19.2.3 isNaN ( number ): ToNumber, then test NaN (COERCES, unlike Number.isNaN).
        const nc = try self.toNumberV(arg0);
        if (nc.isAbrupt()) return nc;
        return .{ .normal = .{ .boolean = std.math.isNan(nc.normal.number) } };
    }
    if (std.mem.eql(u8, name, "isFinite")) {
        // §19.2.2 isFinite ( number ): ToNumber, then test finiteness (COERCES).
        const nc = try self.toNumberV(arg0);
        if (nc.isAbrupt()) return nc;
        return .{ .normal = .{ .boolean = std.math.isFinite(nc.normal.number) } };
    }
    if (std.mem.eql(u8, name, "parseInt")) return parseIntFn(self, args);
    if (std.mem.eql(u8, name, "parseFloat")) return parseFloatFn(self, args);
    // §19.2.6 the URI handlers — encode/decode select via the preserved-char sets.
    if (std.mem.eql(u8, name, "encodeURI")) return uriEncode(self, arg0, .uri);
    if (std.mem.eql(u8, name, "encodeURIComponent")) return uriEncode(self, arg0, .component);
    if (std.mem.eql(u8, name, "decodeURI")) return uriDecode(self, arg0, .uri);
    if (std.mem.eql(u8, name, "decodeURIComponent")) return uriDecode(self, arg0, .component);
    unreachable;
}

/// §19.2.5 parseInt ( string, radix ).
pub fn parseIntFn(self: *Interpreter, args: []const Value) EvalError!Completion {
    const sc = try self.toStringThrowing(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    // §19.2.5 step 2: trim leading StrWhiteSpace + LineTerminator (§22.1.3.32).
    var i: usize = trimLeadingWhiteSpace(s);
    // §19.2.5 steps 3–4: optional sign.
    var sign: f64 = 1;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        if (s[i] == '-') sign = -1;
        i += 1;
    }
    // §19.2.5 steps 7–8: ToInt32(radix); 0 ⇒ default handling.
    var radix: i64 = 0;
    if (args.len > 1) {
        const rc = try self.toNumberV(args[1]);
        if (rc.isAbrupt()) return rc;
        radix = ops.numberToInt32(rc.normal.number);
    }
    var strip_prefix = false;
    if (radix != 0) {
        if (radix < 2 or radix > 36) return .{ .normal = .{ .number = std.math.nan(f64) } };
        if (radix == 16) strip_prefix = true;
    } else {
        radix = 10;
        strip_prefix = true; // a `0x` prefix forces radix 16 below
    }
    // §19.2.5 step 11: an optional `0x`/`0X` prefix (radix 16 or default) selects radix 16.
    if (strip_prefix and i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        i += 2;
        radix = 16;
    }
    // §19.2.5 steps 12–16: parse the longest valid-digit prefix.
    const r: u8 = @intCast(radix);
    var value: f64 = 0;
    var any = false;
    while (i < s.len) : (i += 1) {
        const d = digitValue(s[i]) orelse break;
        if (d >= r) break;
        value = value * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(d));
        any = true;
    }
    if (!any) return .{ .normal = .{ .number = std.math.nan(f64) } };
    return .{ .normal = .{ .number = sign * value } };
}

/// §19.2.4 parseFloat ( string ) — parse the longest leading StrDecimalLiteral prefix.
pub fn parseFloatFn(self: *Interpreter, args: []const Value) EvalError!Completion {
    const sc = try self.toStringThrowing(if (args.len > 0) args[0] else .undefined);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    const rest = s[trimLeadingWhiteSpace(s)..];
    // §19.2.4: an `Infinity` / `+Infinity` / `-Infinity` prefix → ±Infinity.
    {
        var k: usize = 0;
        var sgn: f64 = 1;
        if (k < rest.len and (rest[k] == '+' or rest[k] == '-')) {
            if (rest[k] == '-') sgn = -1;
            k += 1;
        }
        if (std.mem.startsWith(u8, rest[k..], "Infinity")) {
            return .{ .normal = .{ .number = sgn * std.math.inf(f64) } };
        }
    }
    // Scan the longest StrDecimalLiteral prefix: [sign] digits [. digits] [(e|E) [sign] digits].
    var j: usize = 0;
    if (j < rest.len and (rest[j] == '+' or rest[j] == '-')) j += 1;
    var saw_digit = false;
    while (j < rest.len and isAsciiDigit(rest[j])) : (j += 1) saw_digit = true;
    if (j < rest.len and rest[j] == '.') {
        j += 1;
        while (j < rest.len and isAsciiDigit(rest[j])) : (j += 1) saw_digit = true;
    }
    if (!saw_digit) return .{ .normal = .{ .number = std.math.nan(f64) } };
    if (j < rest.len and (rest[j] == 'e' or rest[j] == 'E')) {
        var k = j + 1;
        if (k < rest.len and (rest[k] == '+' or rest[k] == '-')) k += 1;
        var exp_digit = false;
        while (k < rest.len and isAsciiDigit(rest[k])) : (k += 1) exp_digit = true;
        if (exp_digit) j = k; // include the exponent only if it has digits
    }
    const prefix = rest[0..j];
    const n = std.fmt.parseFloat(f64, prefix) catch return .{ .normal = .{ .number = std.math.nan(f64) } };
    return .{ .normal = .{ .number = n } };
}

/// §19.2.6.4/.5 Encode — percent-encode the UTF-8 bytes of `v`, preserving the kind's unescaped
/// (and, for encodeURI, reserved) set. A lone surrogate in the source → URIError.
pub fn uriEncode(self: *Interpreter, v: Value, kind: UriKind) EvalError!Completion {
    const sc = try self.toStringThrowing(v);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            // ASCII: preserve iff in the unescaped (+reserved for encodeURI) set.
            if (isUriPreserved(c, kind)) {
                try out.append(self.arena, c);
            } else {
                try appendPercent(self.arena, &out, c);
            }
            i += 1;
        } else {
            // Multi-byte UTF-8: validate the sequence, reject lone surrogates / invalid bytes.
            const len = std.unicode.utf8ByteSequenceLength(c) catch return self.throwError("URIError", "URI malformed");
            if (i + len > s.len) return self.throwError("URIError", "URI malformed");
            _ = std.unicode.utf8Decode(s[i .. i + len]) catch return self.throwError("URIError", "URI malformed");
            for (s[i .. i + len]) |b| try appendPercent(self.arena, &out, b);
            i += len;
        }
    }
    return .{ .normal = .{ .string = out.items } };
}

/// §19.2.6.2/.3 Decode — turn each `%XX` back into a byte; for decodeURI, an escape whose decoded
/// code point is in the reserved set is preserved as the literal `%XX`. Malformed `%`/UTF-8 →
/// URIError.
pub fn uriDecode(self: *Interpreter, v: Value, kind: UriKind) EvalError!Completion {
    const sc = try self.toStringThrowing(v);
    if (sc.isAbrupt()) return sc;
    const s = sc.normal.string;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            try out.append(self.arena, s[i]);
            i += 1;
            continue;
        }
        // §19.2.6.7 Decode: a `%` must be followed by two hex digits.
        const b0 = decodeHexByte(s, i) orelse return self.throwError("URIError", "URI malformed");
        if (b0 < 0x80) {
            // Single-byte: for decodeURI, preserve a reserved-set escape verbatim.
            if (kind == .uri and isUriReserved(b0)) {
                try out.appendSlice(self.arena, s[i .. i + 3]);
            } else {
                try out.append(self.arena, b0);
            }
            i += 3;
            continue;
        }
        // Multi-byte UTF-8: the lead byte fixes the length; each continuation must be a `%XX`.
        const n: usize = std.unicode.utf8ByteSequenceLength(b0) catch return self.throwError("URIError", "URI malformed");
        var seq: [4]u8 = undefined;
        seq[0] = b0;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const off = i + k * 3;
            const bk = decodeHexByte(s, off) orelse return self.throwError("URIError", "URI malformed");
            if (bk < 0x80 or bk >= 0xC0) return self.throwError("URIError", "URI malformed"); // not a continuation byte
            seq[k] = bk;
        }
        _ = std.unicode.utf8Decode(seq[0..n]) catch return self.throwError("URIError", "URI malformed");
        try out.appendSlice(self.arena, seq[0..n]);
        i += n * 3;
    }
    return .{ .normal = .{ .string = out.items } };
}

/// Dispatch a built-in function (§19/§20). Behavior keyed by `func.native`.
pub fn callNative(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
    switch (func.native) {
        .array_ctor => {
            // §23.1.1.1 / §15.7.14: invoked as a constructor (`new` / `super(...)` from a subclass)
            // the instance is built ON `this_val` (created in `constructNT` proto-linked to
            // new_target.prototype) — flip the pre-created plain object into an Array exotic so
            // `class S extends Array` works. A plain `Array(...)` call (no new_target) makes a fresh
            // array. Mirrors the collection ctors (`.map_ctor` etc. below).
            const arr = if (self.native_new_target != .undefined and this_val == .object) blk: {
                this_val.object.kind = .array; // a plain instance's array backing fields are zero-init
                break :blk this_val.object;
            } else try Object.createArray(self.arena, self.arrayProto());
            // §23.1.1.1: `Array(len)` with a single Number arg sets [[Length]] (a non-uint32 →
            // RangeError); any other arg list becomes the elements. The single-number case is sparse
            // (no eager fill) so `new Array(1e9)` is O(1) and never OOMs.
            if (args.len == 1 and args[0] == .number) {
                const n = args[0].number;
                if (n < 0 or n > 4294967295.0 or n != @floor(n)) {
                    return self.throwError("RangeError", "Invalid array length");
                }
                try arr.arraySetLen(@intFromFloat(n));
            } else {
                for (args) |a| try arr.elements.append(self.arena, a);
                arr.array_length = arr.elements.items.len;
            }
            return .{ .normal = .{ .object = arr } };
        },
        .array_method => return builtin_array.call(self, func.native_name, this_val, args),
        .array_static => return builtin_array_static.staticCall(self, func.native_name, this_val, args),
        .string_method => return builtin_string.call(self, func.native_name, this_val, args),
        .string_static => return builtin_string.staticCall(self, func.native_name, args),
        .map_method => return builtin_collection.mapMethod(self, func.native_name, this_val, args),
        .set_method => return builtin_collection.setMethod(self, func.native_name, this_val, args),
        .weakmap_method => return builtin_collection.weakMapMethod(self, func.native_name, this_val, args),
        .weakset_method => return builtin_collection.weakSetMethod(self, func.native_name, this_val, args),
        .json_parse => return builtin_json.parse(self, args),
        .json_stringify => return builtin_json.stringify(self, args),
        // §24.1.1.1 / §24.2.1.1 / §24.3.1.1 / §24.4.1.1: a collection constructor. A top-level `new`
        // is fully handled in `constructNT` (never reaches here). What DOES reach here is either a
        // plain [[Call]] (`Map()` — new_target undefined → TypeError) or a `super(...)` from a
        // subclass (`class X extends Set` — new_target defined, `this_val` is the derived instance
        // to initialize the [[SetData]]/[[MapData]] slot on).
        .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor => {
            if (self.native_new_target == .undefined or this_val != .object) {
                return self.throwError("TypeError", "Constructor requires 'new'");
            }
            const ic = try interp_collection.initCollectionInstance(self, func.native, this_val.object, args);
            if (ic.isAbrupt()) return ic;
            return .{ .normal = this_val };
        },
        // §28.2.1.1 a plain `Proxy(...)` call (no new) throws; construction is handled in constructNT.
        .proxy_ctor => return self.throwError("TypeError", "Constructor Proxy requires 'new'"),
        .proxy_revocable => return builtin_proxy.revocable(self, args), // §28.2.2.1
        .proxy_revoke => return builtin_proxy.revoke(self, func), // §28.2.2.1.1
        .regexp_ctor => return builtin_regexp.construct(self, args), // §22.2.4.1 RegExp(...) without new
        .regexp_proto_getter => return builtin_regexp.getter(self, func.native_name, this_val), // §22.2.6
        .regexp_to_string => return builtin_regexp.toString(self, this_val), // §22.2.6.17
        .regexp_exec => return builtin_regexp.exec(self, this_val, args), // §22.2.6.2
        .regexp_test => return builtin_regexp.test_(self, this_val, args), // §22.2.6.16
        // §25.1.3.1 a plain `ArrayBuffer(...)` call (no new) throws; construction is in constructNT.
        .array_buffer_ctor => return self.throwError("TypeError", "Constructor ArrayBuffer requires 'new'"),
        .array_buffer_proto_getter => return builtin_arraybuffer.getter(self, func.native_name, this_val), // §25.1.6
        .array_buffer_method => return builtin_arraybuffer.method(self, func.native_name, this_val, args), // §25.1.6.7 slice / resize
        .array_buffer_static => return builtin_arraybuffer.static(self, func.native_name, args), // §25.1.4.1 isView
        // §23.2 TypedArray (spec 083 Phase 2-B). A concrete `<Type>Array(...)` plain call (no new) throws
        // (§23.2.5.1 step 1); the abstract %TypedArray%() always throws (§23.2.1.1). Construction is in
        // constructNT. The prototype getters / methods / statics dispatch by `native_name`.
        .typed_array_ctor => return self.throwError("TypeError", "Constructor TypedArray requires 'new'"),
        .typed_array_abstract_ctor => return builtin_typedarray.constructAbstract(self),
        .typed_array_proto_getter => return builtin_typedarray.getter(self, func.native_name, this_val),
        .typed_array_method => return builtin_typedarray.method(self, func.native_name, this_val, args),
        .typed_array_static => return builtin_typedarray.static(self, func.native_name, this_val, args),
        // §25.3.2.1 a plain `DataView(...)` call (no new) throws; construction is in constructNT.
        .data_view_ctor => return self.throwError("TypeError", "Constructor DataView requires 'new'"),
        .data_view_proto_getter => return builtin_dataview.getter(self, func.native_name, this_val), // §25.3.4.1–.3
        .data_view_method => return builtin_dataview.method(self, func.native_name, this_val, args), // §25.3.4.5–.24
        // §21.4 Date. A plain `Date(...)` call (no new) returns the current-time STRING (§21.4.2.1
        // step 1); `new Date(...)` is handled in constructNT. Statics + prototype methods by name.
        .date_ctor => return builtin_date.callAsFunction(self, args),
        .date_static => return builtin_date.static(self, func.native_name, args),
        .date_proto_method => return builtin_date.method(self, func.native_name, this_val, args),
        .collection_size => return interp_collection.collectionSize(self, func.native_name, this_val),
        .collection_iterator => {
            // `native_name` is "<home>:<which>" — <home> ("map"/"set") brands the receiver, <which>
            // ("keys"/"values"/"entries") selects the yield. So Map.prototype.entries.call(aSet) and
            // Set.prototype.values.call(aMap) both reject (distinct [[MapData]]/[[SetData]] slots).
            const colon = std.mem.indexOfScalar(u8, func.native_name, ':') orelse 0;
            const home: object_mod.CollectionKind = if (std.mem.eql(u8, func.native_name[0..colon], "set")) .set else .map;
            const which = func.native_name[colon + 1 ..];
            const kind: object_mod.IterKind = if (std.mem.eql(u8, which, "keys"))
                .key
            else if (std.mem.eql(u8, which, "entries"))
                .entry
            else
                .value; // "values" / Set keys==values
            return interp_collection.makeCollectionIterator(self, this_val, kind, home);
        },
        .math_method => return builtin_math.call(self, func.native_name, args),
        .reflect_method => return builtin_reflect.reflectMethod(self, func.native_name, args),
        .species_getter => return .{ .normal = this_val }, // §23.1.2.5 get [Symbol.species] returns `this`
        .array_values => return interp_collection.makeArrayIterator(self, this_val, .value), // §23.1.3.34 / Array.prototype[Symbol.iterator]
        .array_keys => return interp_collection.makeArrayIterator(self, this_val, .key), // §23.1.3.18 Array.prototype.keys
        .array_entries => return interp_collection.makeArrayIterator(self, this_val, .entry), // §23.1.3.7 Array.prototype.entries
        .string_iterator => return interp_collection.makeStringIterator(self, this_val), // §22.1.3.36 String.prototype[Symbol.iterator]
        .iterator_next => return interp_collection.iteratorNext(self, this_val), // §23.1.5.2.1 / §22.1.5.2.1 %…IteratorPrototype%.next
        .iterator_helper => {
            // take/drop take a numeric limit (not a callback) → a distinct validation path.
            if (std.mem.eql(u8, func.native_name, "take")) return builtin_iterator.iteratorLimitHelper(self, .take, this_val, args);
            if (std.mem.eql(u8, func.native_name, "drop")) return builtin_iterator.iteratorLimitHelper(self, .drop, this_val, args);
            return builtin_iterator.iteratorHelper(self, func.native_name, this_val, args);
        },
        .iterator_helper_next => return builtin_iterator.helperNext(self, func.native_name, this_val, args), // §27.1.4.x lazy next/return
        .iterator_from => return builtin_iterator.iteratorFrom(self, args), // §27.1.3.1.1
        .iterator_ctor => {
            // §27.1.3.1: the abstract `Iterator` constructor — a direct call (no new_target) or
            // `new Iterator()` (new_target === %Iterator% itself) throws; only a subclass `super()`
            // (new_target is the subclass) succeeds, returning the already-allocated instance.
            const nt = self.native_new_target;
            const iter_ctor: ?*Object = if (self.globals) |g| (if (g.lookup("Iterator")) |b| (if (b.value == .object) b.value.object else null) else null) else null;
            if (nt == .undefined or (nt == .object and iter_ctor != null and nt.object == iter_ctor.?)) {
                return self.throwError("TypeError", "Abstract class Iterator not directly constructable");
            }
            return .{ .normal = this_val };
        },
        .symbol_to_string => return builtin_symbol.toStringMethod(self, func.native_name, this_val), // §20.4.3.3/.4/.5
        .symbol_static => return builtin_symbol.static(self, func.native_name, args), // §20.4.2 for/keyFor
        .symbol_description => return builtin_symbol.description(self, this_val), // §20.4.3.2 get description
        .generator_method => { // §27.5.1.2/.4/.5 %GeneratorPrototype%.next/return/throw
            const arg: Value = if (args.len > 0) args[0] else .undefined;
            const kind: object_mod.ResumeKind = if (std.mem.eql(u8, func.native_name, "return"))
                .ret
            else if (std.mem.eql(u8, func.native_name, "throw"))
                .throw
            else
                .next;
            return interp_async.generatorResume(self, this_val, kind, arg);
        },
        .generator_iterator => return .{ .normal = this_val }, // §27.5.1.1 returns `this`
        .async_generator_method => { // §27.6.1.2/.3/.4 %AsyncGeneratorPrototype%.next/return/throw
            const arg: Value = if (args.len > 0) args[0] else .undefined;
            const kind: object_mod.ResumeKind = if (std.mem.eql(u8, func.native_name, "return"))
                .ret
            else if (std.mem.eql(u8, func.native_name, "throw"))
                .throw
            else
                .next;
            return interp_async.asyncGeneratorResume(self, this_val, kind, arg);
        },
        .async_generator_iterator => return .{ .normal = this_val }, // §27.6.1.5 / §27.1.4.2.4 returns `this`
        .async_from_sync_method => { // §27.1.4.2 %AsyncFromSyncIteratorPrototype%.next/return/throw
            const arg: Value = if (args.len > 0) args[0] else .undefined;
            const has_arg = args.len > 0;
            return interp_async.asyncFromSyncMethod(self, func.native_name, this_val, arg, has_arg);
        },
        .async_from_sync_wrap => { // §27.1.4.4: wrap an awaited value into { value, done }
            const v: Value = if (args.len > 0) args[0] else .undefined;
            const ir = try interp_async.iterResultObject(self, v, func.afs_done);
            return .{ .normal = .{ .object = ir } };
        },
        // §27.2 Promise — the prototype methods (need `this`) + the resolving/finally thunks.
        .promise_then => return interp_async.promiseThen(self, this_val, args),
        .promise_catch => return interp_async.promiseCatch(self, this_val, args),
        .promise_finally => return interp_async.promiseFinally(self, this_val, args),
        .promise_resolve => return interp_async.promiseStaticResolve(self, args),
        .promise_reject => return interp_async.promiseStaticReject(self, args),
        .promise_all => return interp_async.promiseCombinator(self, args, .all),
        .promise_all_settled => return interp_async.promiseCombinator(self, args, .all_settled),
        .promise_any => return interp_async.promiseCombinator(self, args, .any),
        .promise_race => return interp_async.promiseCombinator(self, args, .race),
        .promise_combinator_element => return interp_async.promiseCombinatorElement(self, func, args),
        .promise_resolve_fn, .promise_reject_fn => return interp_async.promiseResolvingFn(self, func, args),
        .promise_finally_thunk => return interp_async.promiseFinallyThunk(self, func, args),
        .test_done => return interp_async.testDone(self, args),
        .global_fn => return globalFn(self, func.native_name, args), // §19.2 global function intrinsics
        .eval_fn => {
            // §19.2.1: reaching `callNative` means INDIRECT eval (`(0,eval)(s)`, `var e=eval; e(s)`,
            // `globalThis.eval(s)`) — the direct case is intercepted in `evalCall` before dispatch.
            // Non-string argument → returned unchanged (§19.2.1 step 2). Otherwise run in the GLOBAL
            // environment with global `this` (§19.2.1.1 with direct=false).
            const arg: Value = if (args.len > 0) args[0] else .undefined;
            if (arg != .string) return .{ .normal = arg };
            const genv = self.globals orelse return self.throwError("EvalError", "eval: no realm");
            // §19.2.1.1: indirect eval's `this` is the global object; save/restore the running
            // `this_val`/`home_object` around the eval so the caller's frame is unperturbed.
            const saved_this = self.this_val;
            const saved_home = self.home_object;
            defer {
                self.this_val = saved_this;
                self.home_object = saved_home;
            }
            self.this_val = if (genv.lookup("%GlobalThis%")) |b| b.value else .undefined;
            self.home_object = null;
            // §19.2.1.1: INDIRECT eval runs in the global context — sloppy unless its own prologue.
            return interp_expr.performEval(self, arg.string, genv, false);
        },
        else => {},
    }
    switch (func.native) {
        .error_ctor => {
            // §20.5.1.1 / §15.7.14: as a constructor (`new`/`super`), initialize the error ON the
            // provided instance (the derived/new object, proto-linked to new_target.prototype) so
            // `class E extends Error` works; a plain `Error(...)` call makes a fresh error.
            const err = if (self.native_new_target != .undefined and this_val == .object)
                this_val.object
            else blk: {
                const pv = func.get("prototype") orelse break :blk try Object.create(self.arena, null);
                break :blk try Object.create(self.arena, if (pv == .object) pv.object else null);
            };
            err.error_data = true; // §20.5 [[ErrorData]] → §20.1.3.6 "Error" tag
            try err.set("name", .{ .string = func.native_name });
            const msg: Value = if (args.len > 0 and args[0] != .undefined)
                .{ .string = try self.toString(args[0]) }
            else
                .{ .string = "" };
            try err.set("message", msg);
            return .{ .normal = .{ .object = err } };
        },
        .aggregate_error_ctor => {
            // §20.5.7.1.1 AggregateError(errors, message) — `errors` is an iterable of the
            // collected errors (IteratorToList); `message` (if not undefined) becomes `.message`.
            const proto: ?*Object = blk: {
                const pv = func.get("prototype") orelse break :blk null;
                break :blk if (pv == .object) pv.object else null;
            };
            const err = try Object.create(self.arena, proto);
            err.error_data = true; // §20.5 [[ErrorData]] → §20.1.3.6 "Error" tag
            try err.set("name", .{ .string = "AggregateError" });
            const msg: Value = if (args.len > 1 and args[1] != .undefined)
                .{ .string = try self.toString(args[1]) }
            else
                .{ .string = "" };
            try err.set("message", msg);
            // §20.5.7.1.1 step 4: ToList the `errors` iterable into the own `errors` data property.
            const errs = try Object.createArray(self.arena, self.arrayProto());
            if (args.len > 0) {
                var list: std.ArrayListUnmanaged(Value) = .empty;
                const lc = try self.iterateToList(args[0], &list);
                if (lc.isAbrupt()) return lc;
                try errs.elements.appendSlice(self.arena, list.items);
            }
            try err.defineData("errors", .{ .object = errs }, true, false, true);
            return .{ .normal = .{ .object = err } };
        },
        .suppressed_error_ctor => {
            // §20.5.8.1 SuppressedError ( error, suppressed, message ) — own `error` / `suppressed`
            // data properties (writable/non-enumerable/configurable) + optional `message`.
            const proto: ?*Object = blk: {
                const pv = func.get("prototype") orelse break :blk null;
                break :blk if (pv == .object) pv.object else null;
            };
            const err = try Object.create(self.arena, proto);
            err.error_data = true; // §20.5 [[ErrorData]] → §20.1.3.6 "Error" tag
            if (args.len > 2 and args[2] != .undefined) {
                try err.set("message", .{ .string = try self.toString(args[2]) });
            }
            try err.defineData("error", if (args.len > 0) args[0] else .undefined, true, false, true);
            try err.defineData("suppressed", if (args.len > 1) args[1] else .undefined, true, false, true);
            return .{ .normal = .{ .object = err } };
        },
        .string_ctor => {
            // §22.1.1.1 String ( value ) — `String(sym)` is the ALLOWED Symbol→string conversion
            // (SymbolDescriptiveString), so it routes through the infallible ToString, not the
            // throwing coercion. An object operand is ToPrimitive(string)'d first (so a wrapper /
            // `valueOf`/`toString` object stringifies via its own method).
            // §22.1.1.1 step 1: if `value` is not present, s is the empty String (NOT "undefined").
            const s: []const u8 = if (args.len == 0) "" else blk: {
                const v = args[0];
                if (v == .object) {
                    const pc = try self.toPrimitive(v, .string);
                    if (pc.isAbrupt()) return pc;
                    break :blk try self.toString(pc.normal);
                }
                break :blk try self.toString(v);
            };
            return interp_expr.wrapperResult(self, .{ .string = s }, this_val); // §22.1.1.1 box [[StringData]] on new/super
        },
        .number_ctor => { // §21.1.1.1 Number ( value ) — ToNumber (ToPrimitive(number) an object first).
            const v: Value = if (args.len > 0) args[0] else .undefined;
            const prim: Value = if (args.len == 0) .{ .number = 0 } else blk: {
                const nc = try self.toNumberV(v);
                if (nc.isAbrupt()) return nc;
                break :blk nc.normal;
            };
            return interp_expr.wrapperResult(self, prim, this_val); // §21.1.1.1 box [[NumberData]] on `new`/`super`
        },
        // §20.3.1.1 Boolean ( value ) — ToBoolean (no ToPrimitive). Box [[BooleanData]] on new/super.
        .boolean_ctor => return interp_expr.wrapperResult(self, .{ .boolean = args.len > 0 and toBoolean(args[0]) }, this_val),
        .number_static => { // §21.1.2.2–.5 isNaN/isFinite/isInteger/isSafeInteger — no coercion
            const x: Value = if (args.len > 0) args[0] else .undefined;
            const isnum = x == .number;
            const v: f64 = if (isnum) x.number else 0;
            const name = func.native_name;
            const res = if (std.mem.eql(u8, name, "isNaN"))
                isnum and std.math.isNan(v)
            else if (std.mem.eql(u8, name, "isFinite"))
                isnum and std.math.isFinite(v)
            else if (std.mem.eql(u8, name, "isInteger"))
                isnum and std.math.isFinite(v) and @floor(v) == v
            else // isSafeInteger
                isnum and std.math.isFinite(v) and @floor(v) == v and @abs(v) <= 9007199254740991;
            return .{ .normal = .{ .boolean = res } };
        },
        .number_method => return builtin_number.method(self, func.native_name, this_val, args), // §21.1.3
        .boolean_method => { // §20.3.3 Boolean.prototype.toString/valueOf — primitive `this` or a Boolean wrapper object
            const b: bool = switch (this_val) {
                .boolean => |x| x,
                // §20.3.3.2/.3 thisBooleanValue: a `new Boolean(x)` wrapper unwraps via [[BooleanData]].
                .object => |o| if (o.primitive != null and o.primitive.? == .boolean) o.primitive.?.boolean else return self.throwError("TypeError", "Boolean.prototype method called on incompatible receiver"),
                else => return self.throwError("TypeError", "Boolean.prototype method called on incompatible receiver"),
            };
            if (std.mem.eql(u8, func.native_name, "valueOf")) return .{ .normal = .{ .boolean = b } };
            return .{ .normal = .{ .string = if (b) "true" else "false" } };
        },
        .object_ctor => {
            // §20.1.1.1 Object ( [ value ] ): an object argument is returned as-is; undefined/null (or
            // no argument) → a fresh ordinary object proto-linked to %Object.prototype%; any other
            // primitive → ToObject(value), boxing into its wrapper (Number/String/Boolean/Symbol/BigInt)
            // so `new Object(1).constructor === Number`.
            const v = if (args.len > 0) args[0] else .undefined;
            if (v == .object) return .{ .normal = v };
            if (v == .undefined or v == .null) return .{ .normal = .{ .object = try Object.create(self.arena, self.objectProto()) } };
            return switch (try self.toObjectForArrayLike(v)) {
                .obj => |o| .{ .normal = .{ .object = o } },
                .abrupt => |c| c,
            };
        },
        .object_to_string => return builtin_object.objectToString(self, this_val),
        // §20.1.3.7 Object.prototype.valueOf returns ToObject(this). For an object receiver that is
        // the receiver itself (so OrdinaryToPrimitive's valueOf step yields a non-primitive and falls
        // through to toString — the default object→"[object Object]" behavior). undefined/null throw.
        .object_value_of => return switch (this_val) {
            .undefined, .null => self.throwError("TypeError", "Object.prototype.valueOf called on null or undefined"),
            else => .{ .normal = this_val },
        },
        .function_ctor => return interp_expr.functionConstructor(self, args),
        .function_proto_noop => return .{ .normal = .undefined }, // §20.2.3 %Function.prototype%() → undefined
        // §10.4.4.6 %ThrowTypeError% — always throws, regardless of args/this. Backs the poison
        // `callee` accessor on a strict/unmapped arguments object.
        .throw_type_error => return self.throwError("TypeError", "'callee', 'caller', and 'arguments' properties may not be accessed on strict mode functions"),
        .object_define_property => return builtin_object.objectDefineProperty(self, args),
        .object_define_properties => return builtin_object.objectDefineProperties(self, args),
        .object_get_own_property_descriptor => return builtin_object.objectGetOwnPropertyDescriptor(self, args),
        .object_get_own_property_descriptors => return builtin_object.objectGetOwnPropertyDescriptors(self, args),
        .object_get_own_property_names => return builtin_object.objectGetOwnPropertyNames(self, args),
        .object_keys => return builtin_object.objectKeysValuesEntries(self, args, .keys),
        .object_values => return builtin_object.objectKeysValuesEntries(self, args, .values),
        .object_entries => return builtin_object.objectKeysValuesEntries(self, args, .entries),
        .object_create => return builtin_object.objectCreate(self, args),
        .object_assign => return builtin_object.objectAssign(self, args),
        .object_from_entries => return builtin_object.objectFromEntries(self, args),
        .object_has_own => return builtin_object.objectHasOwn2(self, args),
        .object_get_own_property_symbols => return builtin_object.objectGetOwnPropertySymbols(self, args),
        .object_group_by => return builtin_object.objectGroupBy(self, args),
        .object_proto_getter => return builtin_object.objectProtoGet(self, this_val),
        .object_proto_setter => return builtin_object.objectProtoSet(self, this_val, args),
        .object_legacy_accessor => return builtin_object.objectLegacyAccessor(self, func.native_name, this_val, args),
        .object_get_prototype_of => return builtin_object.objectGetPrototypeOf(self, args),
        .object_set_prototype_of => return builtin_object.objectSetPrototypeOf(self, args),
        .object_is => return .{ .normal = .{ .boolean = ops.sameValue(if (args.len > 0) args[0] else .undefined, if (args.len > 1) args[1] else .undefined) } },
        .object_freeze => return builtin_object.objectSetIntegrity(self, args, .freeze),
        .object_seal => return builtin_object.objectSetIntegrity(self, args, .seal),
        .object_prevent_extensions => return builtin_object.objectSetIntegrity(self, args, .prevent),
        .object_is_frozen => return builtin_object.objectTestIntegrity(self, args, .frozen),
        .object_is_sealed => return builtin_object.objectTestIntegrity(self, args, .sealed),
        .object_is_extensible => return builtin_object.objectTestIntegrity(self, args, .extensible),
        .object_has_own_property => return builtin_object.objectHasOwnProperty(self, this_val, args),
        .object_property_is_enumerable => return builtin_object.objectPropertyIsEnumerable(self, this_val, args),
        .object_is_prototype_of => return builtin_object.objectIsPrototypeOf(self, this_val, args),
        .function_method => return interp_expr.functionPrototypeMethod(self, func.native_name, this_val, args),
        .bigint_ctor => return builtin_bigint.bigintConstructor(self, args), // §21.2.1.1 BigInt(value)
        .bigint_static => return builtin_bigint.bigintStatic(self, func.native_name, args), // §21.2.2 asIntN/asUintN
        .bigint_method => return builtin_bigint.bigintMethod(self, func.native_name, this_val, args), // §21.2.3 toString/valueOf
        .symbol_ctor => return builtin_symbol.constructor(self, args), // §20.4.1.1 Symbol([description])
        .promise_ctor => return interp_async.promiseConstructor(self, args), // §27.2.3.1 Promise(executor) called w/o new
        .array_ctor, .array_method, .array_static, .string_method, .string_static, .math_method, .reflect_method => unreachable, // handled in the first switch
        .species_getter, .array_values, .array_keys, .array_entries, .string_iterator, .iterator_next, .symbol_to_string => unreachable, // handled in the first switch
        .symbol_static, .symbol_description => unreachable, // handled in the first switch
        .generator_method, .generator_iterator => unreachable, // handled in the first switch
        .async_generator_method, .async_generator_iterator, .async_from_sync_method, .async_from_sync_wrap => unreachable, // handled in the first switch
        .map_method, .set_method, .weakmap_method, .weakset_method => unreachable, // handled in the first switch
        .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor, .collection_size, .collection_iterator => unreachable, // handled in the first switch
        .proxy_ctor, .proxy_revocable, .proxy_revoke => unreachable, // handled in the first switch
        .regexp_ctor, .regexp_proto_getter, .regexp_to_string, .regexp_exec, .regexp_test => unreachable, // handled in the first switch
        // §25.1 ArrayBuffer / §23.2 TypedArray / §25.3 DataView (spec 083) — all handled in the first switch.
        .array_buffer_ctor, .array_buffer_proto_getter, .array_buffer_method, .array_buffer_static => unreachable,
        .typed_array_ctor, .typed_array_abstract_ctor, .typed_array_proto_getter, .typed_array_method, .typed_array_static => unreachable,
        .data_view_ctor, .data_view_proto_getter, .data_view_method => unreachable,
        .date_ctor, .date_static, .date_proto_method => unreachable, // §21.4 handled in the first switch
        .json_parse, .json_stringify => unreachable, // handled in the first switch
        .iterator_helper, .iterator_helper_next, .iterator_from, .iterator_ctor => unreachable, // handled in the first switch
        .promise_then, .promise_catch, .promise_finally, .promise_resolve, .promise_reject => unreachable, // handled in the first switch
        .promise_all, .promise_all_settled, .promise_any, .promise_race, .promise_combinator_element => unreachable, // handled in the first switch
        .promise_resolve_fn, .promise_reject_fn, .promise_finally_thunk, .test_done => unreachable, // handled in the first switch
        .eval_fn => unreachable, // §19.2.1 handled in the first switch (indirect eval path)
        .global_fn => unreachable, // §19.2 handled in the first switch
        .none => unreachable,
    }
}

/// §10.4.4 CreateUnmappedArgumentsObject — the `arguments` exotic given to an ordinary
/// (non-arrow) function. M-subset: an ordinary object (NOT an Array exotic — `Array.isArray` is
/// false) with the call args as indexed data properties + a non-enumerable `length`. §10.4.4.7
/// installs `@@iterator` = %Array.prototype.values% (`array_values`), so `arguments` is iterable
/// (`for (x of arguments)`, `[...arguments]`). The `array_values` native iterates `.elements`, so
/// the args are mirrored there as the iterator's backing store (this does NOT make it an Array —
/// `kind` stays `.ordinary`, so indexed [[Get]]/`length` still read the `properties` map).
/// §10.4.4 a function's `arguments` exotic. A SLOPPY function with a simple parameter list gets a
/// MAPPED object (a `callee` = the function, and indices that alias the live parameter bindings);
/// a strict / non-simple-params function gets an unmapped one. (The strict `callee` poison accessor
/// is deferred — left absent.)
pub fn makeArgumentsObject(self: *Interpreter, args: []const Value, func: *Object, call_env: *Environment, fd: object_mod.FunctionData) EvalError!*Object {
    const ao = try Object.create(self.arena, self.objectProto());
    ao.is_arguments = true; // §10.4.4 [[ParameterMap]] presence → §20.1.3.6 "Arguments" tag
    for (args, 0..) |a, i| {
        const key = try numberToString(self.arena, @floatFromInt(i));
        try ao.set(key, a);
        try ao.elements.append(self.arena, a); // backing store for the @@iterator (array_values)
    }
    try ao.defineData("length", .{ .number = @floatFromInt(args.len) }, true, false, true);
    // §10.4.4.7: arguments[@@iterator] = %ArrayProto_values% (the array_values native, non-enumerable).
    // Keyed by the realm's well-known Symbol.iterator (absent only in a realm-less unit-test eval).
    if (self.wellKnownIterator()) |iter_sym| {
        const values_fn = try Object.createNative(self.arena, .array_values, "[Symbol.iterator]");
        values_fn.prototype = self.functionProto();
        try ao.defineSymbolData(iter_sym, .{ .object = values_fn }, true, false, true);
    }
    if (!fd.strict) {
        // §10.4.4 CreateMappedArgumentsObject: `callee` is the function (writable, non-enumerable,
        // configurable).
        try ao.defineData("callee", .{ .object = func }, true, false, true);
        // The [[ParameterMap]] exists only for a SIMPLE parameter list (no defaults / rest /
        // destructuring). Indices [0, min(argc, paramcount)) alias their parameter binding.
        if (isSimpleParamList(fd)) {
            const n = @min(args.len, fd.params.len);
            if (n > 0) {
                const names = try self.arena.alloc([]const u8, n);
                for (0..n) |i| names[i] = fd.params[i].pattern.identifier;
                // §10.4.4: with duplicate parameter names only the LAST index maps; blank the rest.
                for (0..n) |i| {
                    for (i + 1..n) |j| {
                        if (std.mem.eql(u8, names[i], names[j])) {
                            names[i] = "";
                            break;
                        }
                    }
                }
                ao.mapped_params = .{ .env = call_env, .names = names };
            }
        }
    } else {
        // §10.4.4.6 CreateUnmappedArgumentsObject: `callee` is an accessor whose get AND set are
        // both the realm's %ThrowTypeError% poison, with { enumerable: false, configurable: false }.
        if (self.throwTypeErrorIntrinsic()) |poison| {
            try ao.properties.put(self.arena, "callee", .{
                .payload = .{ .accessor = .{ .get = poison, .set = poison } },
                .enumerable = false,
                .configurable = false,
            });
        }
    }
    return ao;
}

/// §10.4.4: a simple parameter list — every parameter is a plain BindingIdentifier with no
/// initializer, and there is no rest element. Required for a mapped `arguments` object.
pub fn isSimpleParamList(fd: object_mod.FunctionData) bool {
    if (fd.rest != null) return false;
    for (fd.params) |p| {
        if (p.default != null) return false;
        if (p.pattern.* != .identifier) return false;
    }
    return true;
}
