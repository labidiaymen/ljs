//! §25.5 The JSON object — `JSON.parse` and `JSON.stringify`. Dispatched from the interpreter's
//! `callNative` (`json_parse` / `json_stringify`). The grammar (§25.5.1) is strict JSON (NOT the JS
//! grammar): double-quoted strings only, no trailing commas / comments, a restricted number form,
//! whitespace limited to space/tab/LF/CR. Lives in its own file so the interpreter stays the evaluator.
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

// ─── JSON.parse (§25.5.1) ──────────────────────────────────────────────────────────────────────

const Parser = struct {
    it: *Interpreter,
    src: []const u8,
    i: usize = 0,

    fn synErr(self: *Parser) EvalError!Completion {
        return self.it.throwError("SyntaxError", "invalid JSON");
    }

    fn skipWs(self: *Parser) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// §25.5.1 JSONValue — dispatch on the first non-whitespace byte. Returns the parsed Value in
    /// `.normal`, or a SyntaxError completion in `.throw`.
    fn parseValue(self: *Parser) EvalError!Completion {
        self.skipWs();
        if (self.i >= self.src.len) return self.synErr();
        return switch (self.src[self.i]) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => self.parseString(),
            't' => self.keyword("true", .{ .boolean = true }),
            'f' => self.keyword("false", .{ .boolean = false }),
            'n' => self.keyword("null", .null),
            '-', '0'...'9' => self.parseNumber(),
            else => self.synErr(),
        };
    }

    fn keyword(self: *Parser, lit: []const u8, val: Value) EvalError!Completion {
        if (self.i + lit.len > self.src.len or !std.mem.eql(u8, self.src[self.i .. self.i + lit.len], lit)) {
            return self.synErr();
        }
        self.i += lit.len;
        return .{ .normal = val };
    }

    /// §25.5.1 JSONString — a double-quoted string with the JSON escape set; raw control chars (< 0x20)
    /// are a SyntaxError. `\uXXXX` produces a UTF-16 code unit; a surrogate pair is combined, a lone
    /// surrogate is emitted as its 3-byte (WTF-8) form (matching the engine's escape handling).
    fn parseString(self: *Parser) EvalError!Completion {
        // caller guarantees src[i] == '"'
        self.i += 1;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (true) {
            if (self.i >= self.src.len) return self.synErr();
            const c = self.src[self.i];
            if (c == '"') {
                self.i += 1;
                return .{ .normal = .{ .string = buf.items } };
            }
            if (c == '\\') {
                self.i += 1;
                if (self.i >= self.src.len) return self.synErr();
                const e = self.src[self.i];
                self.i += 1;
                switch (e) {
                    '"' => try buf.append(self.it.arena, '"'),
                    '\\' => try buf.append(self.it.arena, '\\'),
                    '/' => try buf.append(self.it.arena, '/'),
                    'b' => try buf.append(self.it.arena, 0x08),
                    'f' => try buf.append(self.it.arena, 0x0C),
                    'n' => try buf.append(self.it.arena, '\n'),
                    'r' => try buf.append(self.it.arena, '\r'),
                    't' => try buf.append(self.it.arena, '\t'),
                    'u' => {
                        const cu = (try self.hex4()) orelse return self.synErr();
                        if (cu >= 0xD800 and cu <= 0xDBFF and self.i + 1 < self.src.len and
                            self.src[self.i] == '\\' and self.src[self.i + 1] == 'u')
                        {
                            const save = self.i;
                            self.i += 2;
                            const lo = (try self.hex4()) orelse return self.synErr();
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                const cp = 0x10000 + ((@as(u21, cu - 0xD800)) << 10) + (lo - 0xDC00);
                                try self.encodeCp(&buf, cp);
                            } else {
                                self.i = save; // not a low surrogate — emit the high one alone, reparse lo next
                                try self.encodeCp(&buf, cu);
                            }
                        } else {
                            try self.encodeCp(&buf, cu);
                        }
                    },
                    else => return self.synErr(),
                }
            } else if (c < 0x20) {
                return self.synErr(); // unescaped control character
            } else {
                try buf.append(self.it.arena, c); // raw byte (UTF-8 multibyte passes through)
                self.i += 1;
            }
        }
    }

    /// Read exactly four hex digits at `i` (advancing past them); null on a non-hex digit.
    fn hex4(self: *Parser) EvalError!?u21 {
        if (self.i + 4 > self.src.len) return null;
        var v: u21 = 0;
        for (0..4) |_| {
            const d = self.src[self.i];
            const nib: u21 = switch (d) {
                '0'...'9' => d - '0',
                'a'...'f' => d - 'a' + 10,
                'A'...'F' => d - 'A' + 10,
                else => return null,
            };
            v = v * 16 + nib;
            self.i += 1;
        }
        return v;
    }

    /// UTF-8 encode a code point into `buf` by hand (WTF-8 for a lone surrogate, which the standard
    /// `utf8Encode` rejects — JSON.parse must preserve it). Cannot fail, so no error to mishandle.
    fn encodeCp(self: *Parser, buf: *std.ArrayListUnmanaged(u8), cp: u21) EvalError!void {
        const a = self.it.arena;
        if (cp < 0x80) {
            try buf.append(a, @intCast(cp));
        } else if (cp < 0x800) {
            try buf.append(a, @intCast(0xC0 | (cp >> 6)));
            try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            try buf.append(a, @intCast(0xE0 | (cp >> 12)));
            try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
        } else {
            try buf.append(a, @intCast(0xF0 | (cp >> 18)));
            try buf.append(a, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
        }
    }

    /// §25.5.1 JSONNumber — `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. No leading zeros, no
    /// leading `+`, a digit required after `.` and after the exponent sign.
    fn parseNumber(self: *Parser) EvalError!Completion {
        const start = self.i;
        if (self.i < self.src.len and self.src[self.i] == '-') self.i += 1;
        // integer part
        if (self.i >= self.src.len) return self.synErr();
        if (self.src[self.i] == '0') {
            self.i += 1;
        } else if (self.src[self.i] >= '1' and self.src[self.i] <= '9') {
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') self.i += 1;
        } else return self.synErr();
        // fraction
        if (self.i < self.src.len and self.src[self.i] == '.') {
            self.i += 1;
            if (self.i >= self.src.len or self.src[self.i] < '0' or self.src[self.i] > '9') return self.synErr();
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') self.i += 1;
        }
        // exponent
        if (self.i < self.src.len and (self.src[self.i] == 'e' or self.src[self.i] == 'E')) {
            self.i += 1;
            if (self.i < self.src.len and (self.src[self.i] == '+' or self.src[self.i] == '-')) self.i += 1;
            if (self.i >= self.src.len or self.src[self.i] < '0' or self.src[self.i] > '9') return self.synErr();
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') self.i += 1;
        }
        const n = std.fmt.parseFloat(f64, self.src[start..self.i]) catch return self.synErr();
        return .{ .normal = .{ .number = n } };
    }

    fn parseObject(self: *Parser) EvalError!Completion {
        self.i += 1; // '{'
        const obj = try Object.create(self.it.arena, self.it.objectProto());
        self.skipWs();
        if (self.i < self.src.len and self.src[self.i] == '}') {
            self.i += 1;
            return .{ .normal = .{ .object = obj } };
        }
        while (true) {
            self.skipWs();
            if (self.i >= self.src.len or self.src[self.i] != '"') return self.synErr();
            const kc = try self.parseString();
            if (kc.isAbrupt()) return kc;
            self.skipWs();
            if (self.i >= self.src.len or self.src[self.i] != ':') return self.synErr();
            self.i += 1;
            const vc = try self.parseValue();
            if (vc.isAbrupt()) return vc;
            // CreateDataProperty: enumerable/writable/configurable; a duplicate key overwrites (last wins).
            try obj.defineData(kc.normal.string, vc.normal, true, true, true);
            self.skipWs();
            if (self.i >= self.src.len) return self.synErr();
            if (self.src[self.i] == ',') {
                self.i += 1;
            } else if (self.src[self.i] == '}') {
                self.i += 1;
                return .{ .normal = .{ .object = obj } };
            } else return self.synErr();
        }
    }

    fn parseArray(self: *Parser) EvalError!Completion {
        self.i += 1; // '['
        const arr = try Object.createArray(self.it.arena, self.it.arrayProto());
        self.skipWs();
        if (self.i < self.src.len and self.src[self.i] == ']') {
            self.i += 1;
            return .{ .normal = .{ .object = arr } };
        }
        while (true) {
            const vc = try self.parseValue();
            if (vc.isAbrupt()) return vc;
            try arr.elements.append(self.it.arena, vc.normal);
            arr.array_length = arr.elements.items.len;
            self.skipWs();
            if (self.i >= self.src.len) return self.synErr();
            if (self.src[self.i] == ',') {
                self.i += 1;
            } else if (self.src[self.i] == ']') {
                self.i += 1;
                return .{ .normal = .{ .object = arr } };
            } else return self.synErr();
        }
    }
};

/// §25.5.1 JSON.parse ( text [ , reviver ] )
pub fn parse(it: *Interpreter, args: []const Value) EvalError!Completion {
    const text: Value = if (args.len > 0) args[0] else .undefined;
    // ToString(text) — coerces (e.g. a number's textual form), throwing on a Symbol.
    const sc = try it.toStringValuePub(text);
    if (sc.isAbrupt()) return sc;
    var p: Parser = .{ .it = it, .src = sc.normal.string };
    const result = try p.parseValue();
    if (result.isAbrupt()) return result;
    p.skipWs();
    if (p.i != p.src.len) return it.throwError("SyntaxError", "unexpected trailing characters");

    const reviver: Value = if (args.len > 1) args[1] else .undefined;
    if (reviver == .object and interp.isCallable(reviver.object)) {
        // §25.5.1.1 InternalizeJSONProperty: walk through a synthetic root holder { "": result }.
        const holder = try Object.create(it.arena, it.objectProto());
        try holder.defineData("", result.normal, true, true, true);
        return internalize(it, holder, "", reviver.object);
    }
    return .{ .normal = result.normal };
}

/// §25.5.1.1 InternalizeJSONProperty ( holder, name, reviver ) — recursively transform the parsed
/// value: recurse into array/object children (replacing per the reviver's result, deleting on
/// undefined), then call reviver(holder, name, value). Abrupt Get/Set/Delete/Call completions propagate.
fn internalize(it: *Interpreter, holder: *Object, name: []const u8, reviver: *Object) EvalError!Completion {
    const vc = try it.getProperty2(.{ .object = holder }, name);
    if (vc.isAbrupt()) return vc;
    const val = vc.normal;
    if (val == .object) {
        const o = val.object;
        if (o.kind == .array) {
            const len = switch (try it.lengthOfArrayLike(o)) {
                .len => |l| l,
                .abrupt => |c| return c,
            };
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const key = try ops.numberToString(it.arena, @floatFromInt(i));
                const ec = try internalize(it, o, key, reviver);
                if (ec.isAbrupt()) return ec;
                const wc = if (ec.normal == .undefined) try it.deleteIndexThrow(o, i) else try it.setIndexThrow(o, i, ec.normal);
                if (wc.isAbrupt()) return wc;
            }
        } else {
            var keys: std.ArrayListUnmanaged(Value) = .empty;
            try it.ownEnumerableKeys(val, &keys);
            for (keys.items) |kv| {
                const key = kv.string;
                const ec = try internalize(it, o, key, reviver);
                if (ec.isAbrupt()) return ec;
                const wc = if (ec.normal == .undefined) try it.deleteProperty(val, key) else try it.setKeyThrow(o, key, ec.normal);
                if (wc.isAbrupt()) return wc;
            }
        }
    }
    // reviver(holder, name, val) — `val` is the same object reference whose children were just mutated.
    return it.callFunction(reviver, &.{ .{ .string = name }, val }, .{ .object = holder });
}

// ─── JSON.stringify (§25.5.2) ──────────────────────────────────────────────────────────────────

/// The serialization state threaded through the recursive SerializeJSONProperty (§25.5.2.1): the gap
/// (indent unit), the current indent, the cycle-detection stack, and an optional explicit key list (an
/// array replacer) / replacer function.
const Stringifier = struct {
    it: *Interpreter,
    gap: []const u8,
    indent: []const u8 = "",
    stack: std.ArrayListUnmanaged(*Object) = .empty,
    replacer_fn: ?*Object = null,
    prop_list: ?[]const []const u8 = null, // an array replacer's key allow-list (in order)
};

/// §25.5.2.1 SerializeJSONProperty ( key, holder ) — returns the JSON text for holder[key] in
/// `.normal.string`, or `.normal.undefined` when the value is to be OMITTED (undefined/function/symbol),
/// or an abrupt completion. The caller decides how an omitted value is rendered (skipped / "null").
fn serializeProperty(s: *Stringifier, key: []const u8, holder: *Object) EvalError!Completion {
    const it = s.it;
    var vc = try it.getProperty2(.{ .object = holder }, key);
    if (vc.isAbrupt()) return vc;
    var value = vc.normal;
    // §25.5.2.1 step 2: if value has a callable toJSON, value = value.toJSON(key).
    if (value == .object) {
        const tc = try it.getProperty2(value, "toJSON");
        if (tc.isAbrupt()) return tc;
        if (tc.normal == .object and interp.isCallable(tc.normal.object)) {
            const rc = try it.callFunction(tc.normal.object, &.{.{ .string = key }}, value);
            if (rc.isAbrupt()) return rc;
            value = rc.normal;
        }
    }
    // §25.5.2.1 step 3: a replacer function transforms value = replacer.call(holder, key, value).
    if (s.replacer_fn) |rf| {
        const rc = try it.callFunction(rf, &.{ .{ .string = key }, value }, .{ .object = holder });
        if (rc.isAbrupt()) return rc;
        value = rc.normal;
    }
    // §25.5.2.1 step 4: unwrap a Number/String/Boolean/BigInt wrapper object to its primitive.
    if (value == .object) {
        if (value.object.primitive) |p| {
            switch (p) {
                .number, .string, .boolean, .bigint => value = p,
                else => {},
            }
        }
    }
    switch (value) {
        .null => return strv("null"),
        .boolean => |b| return strv(if (b) "true" else "false"),
        .string => |str| return .{ .normal = .{ .string = try quote(it, str) } },
        .number => |n| {
            if (std.math.isFinite(n)) return .{ .normal = .{ .string = try ops.numberToString(it.arena, n) } };
            return strv("null"); // NaN / ±Infinity → null
        },
        .bigint => return it.throwError("TypeError", "Do not know how to serialize a BigInt"),
        .object => |o| {
            if (interp.isCallable(o)) return .{ .normal = .undefined }; // a function → omitted
            if (o.kind == .array) return serializeArray(s, o);
            return serializeObject(s, o);
        },
        .undefined, .symbol => return .{ .normal = .undefined }, // omitted
    }
}

fn strv(lit: []const u8) Completion {
    return .{ .normal = .{ .string = lit } };
}

/// §25.5.2.5 QuoteJSONString — wrap in double quotes, escaping `"`, `\`, control chars (and the named
/// short escapes for \b \t \n \f \r). Bytes ≥ 0x20 (incl. UTF-8 multibyte) pass through unescaped.
fn quote(it: *Interpreter, str: []const u8) EvalError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(it.arena, '"');
    for (str) |c| {
        switch (c) {
            '"' => try buf.appendSlice(it.arena, "\\\""),
            '\\' => try buf.appendSlice(it.arena, "\\\\"),
            0x08 => try buf.appendSlice(it.arena, "\\b"),
            0x09 => try buf.appendSlice(it.arena, "\\t"),
            0x0A => try buf.appendSlice(it.arena, "\\n"),
            0x0C => try buf.appendSlice(it.arena, "\\f"),
            0x0D => try buf.appendSlice(it.arena, "\\r"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(it.arena, try std.fmt.allocPrint(it.arena, "\\u{x:0>4}", .{c}));
                } else {
                    try buf.append(it.arena, c);
                }
            },
        }
    }
    try buf.append(it.arena, '"');
    return buf.items;
}

/// Push `o` onto the cycle stack; TypeError if already present (§25.5.2.4/.5 step 1).
fn pushCycle(s: *Stringifier, o: *Object) EvalError!?Completion {
    for (s.stack.items) |e| {
        if (e == o) return try s.it.throwError("TypeError", "Converting circular structure to JSON");
    }
    try s.stack.append(s.it.arena, o);
    return null;
}

/// §25.5.2.4 SerializeJSONObject.
fn serializeObject(s: *Stringifier, o: *Object) EvalError!Completion {
    const it = s.it;
    if (try pushCycle(s, o)) |abrupt| return abrupt;
    const saved_indent = s.indent;
    s.indent = try std.mem.concat(it.arena, u8, &.{ s.indent, s.gap });

    var keys: std.ArrayListUnmanaged(Value) = .empty;
    if (s.prop_list) |pl| {
        for (pl) |k| try keys.append(it.arena, .{ .string = k });
    } else {
        try it.ownEnumerableKeys(.{ .object = o }, &keys);
    }

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    for (keys.items) |kv| {
        const key = kv.string;
        const pc = try serializeProperty(s, key, o);
        if (pc.isAbrupt()) return pc;
        if (pc.normal == .undefined) continue; // omitted
        const member = if (s.gap.len == 0)
            try std.mem.concat(it.arena, u8, &.{ try quote(it, key), ":", pc.normal.string })
        else
            try std.mem.concat(it.arena, u8, &.{ try quote(it, key), ": ", pc.normal.string });
        try parts.append(it.arena, member);
    }

    const result = try joinStructure(it, '{', '}', parts.items, s.gap, s.indent, saved_indent);
    _ = s.stack.pop();
    s.indent = saved_indent;
    return .{ .normal = .{ .string = result } };
}

/// §25.5.2.5 SerializeJSONArray.
fn serializeArray(s: *Stringifier, o: *Object) EvalError!Completion {
    const it = s.it;
    if (try pushCycle(s, o)) |abrupt| return abrupt;
    const saved_indent = s.indent;
    s.indent = try std.mem.concat(it.arena, u8, &.{ s.indent, s.gap });

    const len = switch (try it.lengthOfArrayLike(o)) {
        .len => |l| l,
        .abrupt => |c| return c,
    };
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try ops.numberToString(it.arena, @floatFromInt(i));
        const pc = try serializeProperty(s, key, o);
        if (pc.isAbrupt()) return pc;
        try parts.append(it.arena, if (pc.normal == .undefined) "null" else pc.normal.string); // a hole/undefined → null
    }

    const result = try joinStructure(it, '[', ']', parts.items, s.gap, s.indent, saved_indent);
    _ = s.stack.pop();
    s.indent = saved_indent;
    return .{ .normal = .{ .string = result } };
}

/// Join serialized members into `{...}` / `[...]`, applying the pretty-print gap/indent (§25.5.2.4/.5).
fn joinStructure(it: *Interpreter, open: u8, close: u8, parts: []const []const u8, gap: []const u8, indent: []const u8, prev_indent: []const u8) EvalError![]const u8 {
    if (parts.len == 0) return try std.fmt.allocPrint(it.arena, "{c}{c}", .{ open, close });
    if (gap.len == 0) {
        const inner = try std.mem.join(it.arena, ",", parts);
        return try std.fmt.allocPrint(it.arena, "{c}{s}{c}", .{ open, inner, close });
    }
    const sep = try std.mem.concat(it.arena, u8, &.{ ",\n", indent });
    const inner = try std.mem.join(it.arena, sep, parts);
    return try std.mem.concat(it.arena, u8, &.{ &.{open}, "\n", indent, inner, "\n", prev_indent, &.{close} });
}

/// §25.5.2 JSON.stringify ( value [ , replacer [ , space ] ] )
pub fn stringify(it: *Interpreter, args: []const Value) EvalError!Completion {
    const value: Value = if (args.len > 0) args[0] else .undefined;
    const replacer: Value = if (args.len > 1) args[1] else .undefined;
    const space_arg: Value = if (args.len > 2) args[2] else .undefined;

    var s: Stringifier = .{ .it = it, .gap = "" };

    // §25.5.2 step 4: replacer is either a callable (transform) or an array (property allow-list).
    if (replacer == .object) {
        if (interp.isCallable(replacer.object)) {
            s.replacer_fn = replacer.object;
        } else if (replacer.object.kind == .array) {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            const len = switch (try it.lengthOfArrayLike(replacer.object)) {
                .len => |l| l,
                .abrupt => |c| return c,
            };
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const ec = try it.getProperty2(replacer, try ops.numberToString(it.arena, @floatFromInt(i)));
                if (ec.isAbrupt()) return ec;
                // §25.5.2 step 4.b.iii: a String / Number element (or wrapper) becomes a key string.
                const item: ?[]const u8 = switch (ec.normal) {
                    .string => |str| str,
                    .number => |n| try ops.numberToString(it.arena, n),
                    .object => |o| if (o.primitive) |p| switch (p) {
                        .string => p.string,
                        .number => try ops.numberToString(it.arena, p.number),
                        else => null,
                    } else null,
                    else => null,
                };
                if (item) |k| {
                    var dup = false; // duplicates are ignored (kept once, first occurrence)
                    for (list.items) |e| if (std.mem.eql(u8, e, k)) {
                        dup = true;
                        break;
                    };
                    if (!dup) try list.append(it.arena, k);
                }
            }
            s.prop_list = list.items;
        }
    }

    // §25.5.2 step 5/6: space → the gap (a Number clamps to [0,10] spaces; a String takes ≤10 chars).
    var space = space_arg;
    if (space == .object) {
        if (space.object.primitive) |p| {
            if (p == .number or p == .string) space = p;
        }
    }
    switch (space) {
        .number => |n| {
            const k: usize = @intFromFloat(@max(0, @min(10, @floor(n))));
            const buf = try it.arena.alloc(u8, k);
            @memset(buf, ' ');
            s.gap = buf;
        },
        .string => |str| s.gap = if (str.len <= 10) str else str[0..10],
        else => {},
    }

    // §25.5.2 step 11: wrap in a root holder { "": value } and serialize key "".
    const holder = try Object.create(it.arena, it.objectProto());
    try holder.defineData("", value, true, true, true);
    const pc = try serializeProperty(&s, "", holder);
    if (pc.isAbrupt()) return pc;
    return .{ .normal = pc.normal }; // a top-level omitted value → undefined (JSON.stringify(undefined))
}
