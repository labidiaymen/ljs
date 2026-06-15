//! Tree-walking interpreter (ECMA-262 §13–§14). M1 adds statement evaluation over an
//! Environment chain: declarations (`var`/`let`/`const`), assignment, blocks (lexical scope),
//! the `let`/`const` temporal dead zone, and `const` reassignment errors. Each step mirrors a
//! spec algorithm and carries its clause reference. A step-cap watchdog bounds runaway runs.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const Object = @import("object.zig").Object;

pub const EvalError = error{ StepLimitExceeded, OutOfMemory };

pub const Interpreter = struct {
    arena: std.mem.Allocator,
    steps: u64 = 0,
    step_limit: u64 = 10_000_000,
    depth: u32 = 0,
    // Recursion-depth guard: a tree-walker recurses on the native stack, so deeply nested
    // expressions would overflow it and SIGSEGV. We throw RangeError first (as V8 does:
    // "Maximum call stack size exceeded"). Conservative for the larger M1 frames; raise once
    // eval runs on a dedicated large-stack thread.
    max_depth: u32 = 1000,

    pub fn run(self: *Interpreter, program: ast.Program, env: *Environment) EvalError!Completion {
        var last: Completion = .{ .normal = .undefined };
        for (program.statements) |stmt| {
            last = try self.evalStmt(stmt, env);
            if (last.isAbrupt()) return last; // ReturnIfAbrupt (§5.2.3.4)
        }
        return last;
    }

    fn tick(self: *Interpreter) EvalError!void {
        self.steps += 1;
        if (self.steps > self.step_limit) return EvalError.StepLimitExceeded;
    }

    // ── statements ──────────────────────────────────────────────────────────

    fn evalStmt(self: *Interpreter, stmt: ast.Stmt, env: *Environment) EvalError!Completion {
        try self.tick();
        switch (stmt) {
            .expr => |e| return self.evalExpr(e, env),
            .declaration => |d| {
                // §14.3 declarations. Deliberate, documented M1 cuts (no hoisting pass yet):
                //   (a) `var` is block-scoped here, NOT function/global-hoisted (§14.3.2/§10.2.11);
                //   (b) the let/const temporal dead zone is not enforced — bindings are created
                //       initialized, so the `!initialized` check below is staged, not yet live;
                //   (c) duplicate lexical declarations are not yet a SyntaxError (§14.3.1).
                // Tightened in later M1 cycles. None of these affect the US1 acceptance scenarios.
                for (d.decls) |dec| {
                    var v: Value = .undefined;
                    if (dec.init) |ie| {
                        const c = try self.evalExpr(ie, env);
                        if (c.isAbrupt()) return c;
                        v = c.normal;
                    }
                    try env.declare(dec.name, v, d.kind != .const_decl, true);
                }
                return .{ .normal = .undefined };
            },
            .block => |stmts| {
                // §14.2 Block — runs in a fresh declarative environment (lexical scope).
                const child = try Environment.create(self.arena, env);
                var last: Completion = .{ .normal = .undefined };
                for (stmts) |s| {
                    last = try self.evalStmt(s, child);
                    if (last.isAbrupt()) return last;
                }
                return last;
            },
        }
    }

    // ── expressions ─────────────────────────────────────────────────────────

    fn evalExpr(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!Completion {
        try self.tick();
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > self.max_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
        switch (node.*) {
            .number => |n| return .{ .normal = .{ .number = n } },
            .string => |s| return .{ .normal = .{ .string = s } },
            .boolean => |b| return .{ .normal = .{ .boolean = b } },
            .null => return .{ .normal = .null },
            .identifier => |name| {
                // §9.4.2 ResolveBinding + §6.2.5.5 GetValue + §9.1.1.1.6 GetBindingValue.
                const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                if (!b.initialized) return self.throwError("ReferenceError", name); // TDZ (staged; see declaration note)
                return .{ .normal = b.value };
            },
            .assign => |a| {
                // §13.15.2 AssignmentExpression; mutation via §6.2.5.6 PutValue (identifier target).
                const c = try self.evalExpr(a.value, env);
                if (c.isAbrupt()) return c;
                const b = env.lookup(a.name) orelse return self.throwError("ReferenceError", a.name);
                if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                b.value = c.normal;
                return .{ .normal = c.normal };
            },
            .unary => |u| return self.evalUnary(u.op, u.operand, env),
            .binary => |b| return self.evalBinary(b.op, b.left, b.right, env),
            .object_literal => |props| {
                // §13.2.5 ObjectLiteral evaluation — fresh ordinary object, no proto for M1.
                const obj = try Object.create(self.arena, null);
                for (props) |p| {
                    const c = try self.evalExpr(p.value, env);
                    if (c.isAbrupt()) return c;
                    try obj.set(p.key, c.normal);
                }
                return .{ .normal = .{ .object = obj } };
            },
            .member => |m| {
                const oc = try self.evalExpr(m.object, env);
                if (oc.isAbrupt()) return oc;
                return self.getProperty(oc.normal, m.name);
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env);
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env);
                if (kc.isAbrupt()) return kc;
                return self.getProperty(oc.normal, try self.toString(kc.normal));
            },
            .assign_member => |am| {
                const oc = try self.evalExpr(am.object, env);
                if (oc.isAbrupt()) return oc;
                const vc = try self.evalExpr(am.value, env);
                if (vc.isAbrupt()) return vc;
                return self.setProperty(oc.normal, am.name, vc.normal);
            },
            .assign_index => |ai| {
                const oc = try self.evalExpr(ai.object, env);
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ai.key, env);
                if (kc.isAbrupt()) return kc;
                const vc = try self.evalExpr(ai.value, env);
                if (vc.isAbrupt()) return vc;
                return self.setProperty(oc.normal, try self.toString(kc.normal), vc.normal);
            },
        }
    }

    /// §10.1.8 [[Get]]. Property access on null/undefined throws (§13.3); other primitives
    /// have no own properties in M1 (no boxing yet) → undefined.
    fn getProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        switch (base) {
            .object => |o| return .{ .normal = o.get(key) orelse .undefined },
            .undefined, .null => return self.throwError("TypeError", "Cannot read properties of null or undefined"),
            else => return .{ .normal = .undefined },
        }
    }

    /// §10.1.9 [[Set]]. Setting on null/undefined throws; on other primitives is a no-op in M1.
    fn setProperty(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
        switch (base) {
            .object => |o| {
                try o.set(key, value);
                return .{ .normal = value };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot set properties of null or undefined"),
            else => return .{ .normal = value },
        }
    }

    fn evalUnary(self: *Interpreter, op: ast.UnaryOp, operand: *const ast.Node, env: *Environment) EvalError!Completion {
        const c = try self.evalExpr(operand, env);
        if (c.isAbrupt()) return c;
        const v = c.normal;
        return switch (op) {
            .plus => .{ .normal = .{ .number = toNumber(v) } }, // §13.5.4
            .minus => .{ .normal = .{ .number = -toNumber(v) } }, // §13.5.5
            .not => .{ .normal = .{ .boolean = !toBoolean(v) } }, // §13.5.7
        };
    }

    fn evalBinary(self: *Interpreter, op: ast.BinaryOp, ln: *const ast.Node, rn: *const ast.Node, env: *Environment) EvalError!Completion {
        const lc = try self.evalExpr(ln, env);
        if (lc.isAbrupt()) return lc;
        const rc = try self.evalExpr(rn, env);
        if (rc.isAbrupt()) return rc;
        const l = lc.normal;
        const r = rc.normal;

        switch (op) {
            .add => { // §13.8.1 Addition / §13.15.3 ApplyStringOrNumericBinaryOperator: concat if either is String, else numeric.
                if (l == .string or r == .string) {
                    const ls = try self.toString(l);
                    const rs = try self.toString(r);
                    return .{ .normal = .{ .string = try std.mem.concat(self.arena, u8, &.{ ls, rs }) } };
                }
                return .{ .normal = .{ .number = toNumber(l) + toNumber(r) } };
            },
            .sub => return .{ .normal = .{ .number = toNumber(l) - toNumber(r) } },
            .mul => return .{ .normal = .{ .number = toNumber(l) * toNumber(r) } },
            .div => return .{ .normal = .{ .number = toNumber(l) / toNumber(r) } },
            .mod => return .{ .normal = .{ .number = @rem(toNumber(l), toNumber(r)) } },
            .lt => return .{ .normal = .{ .boolean = relational(l, r, .lt) } },
            .gt => return .{ .normal = .{ .boolean = relational(l, r, .gt) } },
            .le => return .{ .normal = .{ .boolean = relational(l, r, .le) } },
            .ge => return .{ .normal = .{ .boolean = relational(l, r, .ge) } },
            .eq => return .{ .normal = .{ .boolean = looseEquals(l, r) } },
            .ne => return .{ .normal = .{ .boolean = !looseEquals(l, r) } },
            .seq => return .{ .normal = .{ .boolean = strictEquals(l, r) } },
            .sne => return .{ .normal = .{ .boolean = !strictEquals(l, r) } },
        }
    }

    /// M1: typed Error objects don't exist yet (Cycle E), so a thrown error is a string
    /// "<Kind>: <message>". Classification in the harness still sees a throw; exact-type
    /// matching is tightened once real Error objects land.
    fn throwError(self: *Interpreter, kind: []const u8, msg: []const u8) EvalError!Completion {
        const s = try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ kind, msg });
        return .{ .throw = .{ .string = s } };
    }

    /// §7.1.17 ToString (subset; primitives only).
    fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
        return switch (v) {
            .string => |s| s,
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| numberToString(self.arena, n),
            .object => "[object Object]", // §20.1.3.6 (M1 stub; ToPrimitive deferred)
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
        .object => std.math.nan(f64), // §7.1.4 ToNumber(object) → ToPrimitive; M1 stub → NaN
    };
}

/// §7.1.2 ToBoolean.
fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
        .object => true, // §7.1.2 — objects are always truthy
    };
}

const RelOp = enum { lt, gt, le, ge };

/// §7.2.13 / §13.10 Relational comparison.
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
        .object => |o| r == .object and r.object == o, // reference equality
    };
}

/// §7.2.15 IsLooselyEqual (==) — primitive subset.
fn looseEquals(l: Value, r: Value) bool {
    if (@as(std.meta.Tag(Value), l) == @as(std.meta.Tag(Value), r)) return strictEquals(l, r);
    if ((l == .null and r == .undefined) or (l == .undefined and r == .null)) return true;
    if (l == .undefined or l == .null or r == .undefined or r == .null) return false;
    return toNumber(l) == toNumber(r);
}

/// §6.1.6.1.21 Number::toString (subset).
fn numberToString(arena: std.mem.Allocator, n: f64) error{OutOfMemory}![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isPositiveInf(n)) return "Infinity";
    if (std.math.isNegativeInf(n)) return "-Infinity";
    if (n == @floor(n) and @abs(n) < 1e21) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}
