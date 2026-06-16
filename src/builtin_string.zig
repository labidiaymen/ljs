//! §22.1.3 `String.prototype` methods. `this` is the receiver (boxed transparently in
//! getProperty). M2 is byte-oriented (ASCII-correct; full Unicode/UTF-16 semantics deferred).
const std = @import("std");
const interp = @import("interpreter.zig");
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const ops = @import("abstract_ops.zig");

pub fn call(it: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
    // §22.1.3 the receiver is a primitive String, or a `new String(x)` wrapper (unwrap via [[StringData]]),
    // or any other value coerced via ToString.
    const s = if (this_val == .string)
        this_val.string
    else if (this_val == .object and this_val.object.primitive != null and this_val.object.primitive.? == .string)
        this_val.object.primitive.?.string
    else
        try it.toString(this_val);
    const eql = std.mem.eql;

    if (eql(u8, name, "toString") or eql(u8, name, "valueOf")) {
        // §22.1.3.28/.32 thisStringValue: only a primitive String or a String wrapper object is valid.
        if (this_val != .string and !(this_val == .object and this_val.object.primitive != null and this_val.object.primitive.? == .string)) {
            return it.throwError("TypeError", "String.prototype method called on incompatible receiver");
        }
        return str(s);
    }

    if (eql(u8, name, "charAt")) {
        const i = idxArg(args, 0);
        if (i) |n| if (n < s.len) return str(s[n .. n + 1]);
        return str("");
    }
    if (eql(u8, name, "charCodeAt")) {
        const i = idxArg(args, 0);
        if (i) |n| if (n < s.len) return num(@floatFromInt(s[n]));
        return num(std.math.nan(f64));
    }
    if (eql(u8, name, "indexOf")) {
        const needle = try argStr(it, args, 0);
        if (std.mem.indexOf(u8, s, needle)) |pos| return num(@floatFromInt(pos));
        return num(-1);
    }
    if (eql(u8, name, "includes")) {
        const needle = try argStr(it, args, 0);
        return .{ .normal = .{ .boolean = std.mem.indexOf(u8, s, needle) != null } };
    }
    if (eql(u8, name, "toUpperCase") or eql(u8, name, "toLowerCase")) {
        const upper = eql(u8, name, "toUpperCase");
        const out = try it.arena.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
        return str(out);
    }
    if (eql(u8, name, "slice") or eql(u8, name, "substring")) {
        const start = clamp(idxArg(args, 0), s.len, 0);
        const end = clamp(idxArg(args, 1), s.len, s.len);
        const lo = @min(start, end);
        const hi = @max(start, end);
        return str(s[lo..hi]); // substring swaps if start>end; slice w/o negatives behaves the same here
    }
    if (eql(u8, name, "split")) {
        const out = try Object.createArray(it.arena, it.arrayProto());
        if (args.len == 0 or args[0] == .undefined) {
            try out.elements.append(it.arena, .{ .string = s });
        } else {
            const sep = try it.toString(args[0]);
            if (sep.len == 0) {
                for (s) |_| {} // fallthrough below handles char split
                var i: usize = 0;
                while (i < s.len) : (i += 1) try out.elements.append(it.arena, .{ .string = s[i .. i + 1] });
            } else {
                var rest = s;
                while (std.mem.indexOf(u8, rest, sep)) |pos| {
                    try out.elements.append(it.arena, .{ .string = rest[0..pos] });
                    rest = rest[pos + sep.len ..];
                }
                try out.elements.append(it.arena, .{ .string = rest });
            }
        }
        return .{ .normal = .{ .object = out } };
    }
    return .{ .normal = .undefined };
}

fn str(s: []const u8) Completion {
    return .{ .normal = .{ .string = s } };
}
fn num(n: f64) Completion {
    return .{ .normal = .{ .number = n } };
}
fn idxArg(args: []const Value, i: usize) ?usize {
    if (i >= args.len) return null;
    const n = ops.toNumber(args[i]);
    if (std.math.isNan(n) or n < 0) return 0;
    return @intFromFloat(n);
}
fn argStr(it: *Interpreter, args: []const Value, i: usize) EvalError![]const u8 {
    return if (i < args.len) it.toString(args[i]) else "undefined";
}
fn clamp(maybe: ?usize, len: usize, default: usize) usize {
    const v = maybe orelse return default;
    return @min(v, len);
}
