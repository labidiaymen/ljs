//! ECMA-262 abstract operations — type conversion (§7.1), comparison (§7.2), plus the `typeof`
//! and `instanceof` operator helpers. Pure functions over `Value` (no interpreter state);
//! `toString`/`numberToString` take an arena for string building. Extracted from the interpreter
//! so the evaluator stays focused and these stay 1:1 with their spec clauses.
const std = @import("std");
const Value = @import("value.zig").Value;

/// §7.1.4 ToNumber (subset; primitives only).
pub fn toNumber(v: Value) f64 {
    return switch (v) {
        .number => |n| n,
        .undefined => std.math.nan(f64),
        .null => 0,
        .boolean => |b| if (b) 1 else 0,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len == 0) break :blk 0;
            break :blk std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        },
        .object => std.math.nan(f64), // ToPrimitive deferred → NaN
    };
}

/// §7.1.2 ToBoolean.
pub fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
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
        .object => |o| blk: {
            if (o.kind != .array) break :blk "[object Object]"; // §20.1.3.6 (ToPrimitive deferred)
            var buf: std.ArrayList(u8) = .empty;
            for (o.elements.items, 0..) |el, i| {
                if (i > 0) try buf.appendSlice(arena, ",");
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
    if (n == @floor(n) and @abs(n) < 1e21) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// §13.5.3 The typeof Operator.
pub fn typeOf(v: Value) []const u8 {
    return switch (v) {
        .undefined => "undefined",
        .null => "object", // the historical quirk
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .object => |o| if (o.kind == .function) "function" else "object",
    };
}

pub const RelOp = enum { lt, gt, le, ge };

/// §7.2.13 / §13.10 Relational comparison.
pub fn relational(l: Value, r: Value, op: RelOp) bool {
    if (l == .string and r == .string) {
        const order = std.mem.order(u8, l.string, r.string);
        return switch (op) {
            .lt => order == .lt,
            .gt => order == .gt,
            .le => order != .gt,
            .ge => order != .lt,
        };
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

/// §7.2.16 IsStrictlyEqual (===).
pub fn strictEquals(l: Value, r: Value) bool {
    return switch (l) {
        .undefined => r == .undefined,
        .null => r == .null,
        .boolean => |b| r == .boolean and r.boolean == b,
        .number => |n| r == .number and r.number == n,
        .string => |s| r == .string and std.mem.eql(u8, s, r.string),
        .object => |o| r == .object and r.object == o, // reference equality
    };
}

/// §7.2.15 IsLooselyEqual (==) — primitive subset.
pub fn looseEquals(l: Value, r: Value) bool {
    if (@as(std.meta.Tag(Value), l) == @as(std.meta.Tag(Value), r)) return strictEquals(l, r);
    if ((l == .null and r == .undefined) or (l == .undefined and r == .null)) return true;
    if (l == .undefined or l == .null or r == .undefined or r == .null) return false;
    return toNumber(l) == toNumber(r);
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
