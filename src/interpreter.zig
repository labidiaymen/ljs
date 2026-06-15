//! Tree-walking interpreter for the M0 expression grammar. Each evaluation step mirrors an
//! ECMA-262 algorithm and carries its clause reference. Returns a Completion Record; a
//! step-cap watchdog (research D8) surfaces runaway evaluation as `error.StepLimitExceeded`
//! so the harness can record it without hanging.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;

pub const EvalError = error{ StepLimitExceeded, OutOfMemory };

pub const Interpreter = struct {
    arena: std.mem.Allocator,
    steps: u64 = 0,
    step_limit: u64 = 10_000_000,

    pub fn run(self: *Interpreter, program: ast.Program) EvalError!Completion {
        var last: Completion = .{ .normal = .undefined };
        for (program.statements) |stmt| {
            last = try self.eval(stmt);
            if (last.isAbrupt()) return last; // ReturnIfAbrupt (§5.2.3.4)
        }
        return last;
    }

    fn eval(self: *Interpreter, node: *const ast.Node) EvalError!Completion {
        self.steps += 1;
        if (self.steps > self.step_limit) return EvalError.StepLimitExceeded;

        switch (node.*) {
            .number => |n| return .{ .normal = .{ .number = n } },
            .string => |s| return .{ .normal = .{ .string = s } },
            .boolean => |b| return .{ .normal = .{ .boolean = b } },
            .null => return .{ .normal = .null },
            .unary => |u| return self.evalUnary(u.op, u.operand),
            .binary => |b| return self.evalBinary(b.op, b.left, b.right),
        }
    }

    fn evalUnary(self: *Interpreter, op: ast.UnaryOp, operand: *const ast.Node) EvalError!Completion {
        const c = try self.eval(operand);
        if (c.isAbrupt()) return c;
        const v = c.normal;
        return switch (op) {
            .plus => .{ .normal = .{ .number = toNumber(v) } }, // §13.5.4 Unary +
            .minus => .{ .normal = .{ .number = -toNumber(v) } }, // §13.5.5 Unary -
            .not => .{ .normal = .{ .boolean = !toBoolean(v) } }, // §13.5.7 Logical NOT
        };
    }

    fn evalBinary(self: *Interpreter, op: ast.BinaryOp, ln: *const ast.Node, rn: *const ast.Node) EvalError!Completion {
        const lc = try self.eval(ln);
        if (lc.isAbrupt()) return lc;
        const rc = try self.eval(rn);
        if (rc.isAbrupt()) return rc;
        const l = lc.normal;
        const r = rc.normal;

        switch (op) {
            // §13.15.3 Addition: if either operand is a String, concatenate; else add numbers.
            .add => {
                if (l == .string or r == .string) {
                    const ls = try self.toString(l);
                    const rs = try self.toString(r);
                    const out = try std.mem.concat(self.arena, u8, &.{ ls, rs });
                    return .{ .normal = .{ .string = out } };
                }
                return .{ .normal = .{ .number = toNumber(l) + toNumber(r) } };
            },
            .sub => return .{ .normal = .{ .number = toNumber(l) - toNumber(r) } },
            .mul => return .{ .normal = .{ .number = toNumber(l) * toNumber(r) } },
            .div => return .{ .normal = .{ .number = toNumber(l) / toNumber(r) } },
            .mod => return .{ .normal = .{ .number = @rem(toNumber(l), toNumber(r)) } },

            // §13.10 Relational
            .lt => return .{ .normal = .{ .boolean = relational(l, r, .lt) } },
            .gt => return .{ .normal = .{ .boolean = relational(l, r, .gt) } },
            .le => return .{ .normal = .{ .boolean = relational(l, r, .le) } },
            .ge => return .{ .normal = .{ .boolean = relational(l, r, .ge) } },

            // §13.11 Equality
            .eq => return .{ .normal = .{ .boolean = looseEquals(l, r) } },
            .ne => return .{ .normal = .{ .boolean = !looseEquals(l, r) } },
            .seq => return .{ .normal = .{ .boolean = strictEquals(l, r) } },
            .sne => return .{ .normal = .{ .boolean = !strictEquals(l, r) } },
        }
    }

    /// §7.1.17 ToString (subset; primitives only).
    fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
        return switch (v) {
            .string => |s| s,
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| numberToString(self.arena, n),
        };
    }
};

/// §7.1.4 ToNumber (subset; primitives only).
fn toNumber(v: Value) f64 {
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
    };
}

/// §7.1.2 ToBoolean.
fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
    };
}

const RelOp = enum { lt, gt, le, ge };

/// §7.2.13 IsLessThan and the relational operators (§13.10). String/string compares
/// lexicographically by code unit; otherwise both sides are coerced with ToNumber.
fn relational(l: Value, r: Value, op: RelOp) bool {
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
fn strictEquals(l: Value, r: Value) bool {
    return switch (l) {
        .undefined => r == .undefined,
        .null => r == .null,
        .boolean => |b| r == .boolean and r.boolean == b,
        .number => |n| r == .number and r.number == n,
        .string => |s| r == .string and std.mem.eql(u8, s, r.string),
    };
}

/// §7.2.15 IsLooselyEqual (==) — primitive subset.
fn looseEquals(l: Value, r: Value) bool {
    if (@as(std.meta.Tag(Value), l) == @as(std.meta.Tag(Value), r)) return strictEquals(l, r);
    // null == undefined
    if ((l == .null and r == .undefined) or (l == .undefined and r == .null)) return true;
    if (l == .undefined or l == .null or r == .undefined or r == .null) return false;
    // Any number/boolean/string mix → compare as numbers.
    return toNumber(l) == toNumber(r);
}

/// §6.1.6.1.21 Number::toString (subset matching value.zig's display form).
fn numberToString(arena: std.mem.Allocator, n: f64) error{OutOfMemory}![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isPositiveInf(n)) return "Infinity";
    if (std.math.isNegativeInf(n)) return "-Infinity";
    if (n == @floor(n) and @abs(n) < 1e21) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}
