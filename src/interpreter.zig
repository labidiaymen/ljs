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
const ops = @import("abstract_ops.zig");
const builtin_array = @import("builtin_array.zig");
const builtin_string = @import("builtin_string.zig");

// ECMA-262 abstract operations live in abstract_ops.zig; alias them so call sites read naturally.
const toNumber = ops.toNumber;
const toBoolean = ops.toBoolean;
const typeOf = ops.typeOf;
const relational = ops.relational;
const strictEquals = ops.strictEquals;
const looseEquals = ops.looseEquals;
const instanceOf = ops.instanceOf;
const parseIndex = ops.parseIndex;

pub const EvalError = error{ StepLimitExceeded, OutOfMemory };

pub const Interpreter = struct {
    arena: std.mem.Allocator,
    steps: u64 = 0,
    step_limit: u64 = 10_000_000,
    depth: u32 = 0,
    // Recursion-depth guard: a tree-walker recurses on the native stack, so deeply nested
    // expressions/calls would overflow it and SIGSEGV. We throw RangeError first (as V8 does:
    // "Maximum call stack size exceeded"). Conservative for the larger M1 frames; raise once
    // eval runs on a dedicated large-stack thread.
    max_depth: u32 = 400,
    /// The current `this` binding (§9.4.5 GetThisEnvironment, M1 subset): set by method calls,
    /// undefined otherwise. Saved/restored around each [[Call]].
    this_val: Value = .undefined,
    /// The realm's global environment — used to resolve the Error family for engine-thrown
    /// errors (so they carry the right prototype + name). Set by the engine after setup.
    globals: ?*Environment = null,

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
                return self.runBlock(stmts, try Environment.create(self.arena, env));
            },
            .func_decl => |f| {
                // §15.2 — bind a function object to its name in the current scope.
                const obj = try Object.createFunction(self.arena, .{ .params = f.params, .body = f.body, .closure = env });
                if (f.name) |name| try env.declare(name, .{ .object = obj }, true, true);
                return .{ .normal = .undefined };
            },
            .ret => |maybe_expr| {
                // §14.10 ReturnStatement.
                if (maybe_expr) |e| {
                    const c = try self.evalExpr(e, env);
                    if (c.isAbrupt()) return c;
                    return .{ .ret = c.normal };
                }
                return .{ .ret = .undefined };
            },
            .if_stmt => |s| {
                // §14.6 IfStatement.
                const cc = try self.evalExpr(s.cond, env);
                if (cc.isAbrupt()) return cc;
                if (toBoolean(cc.normal)) return self.evalStmt(s.then.*, env);
                if (s.otherwise) |els| return self.evalStmt(els.*, env);
                return .{ .normal = .undefined };
            },
            .while_stmt => |s| {
                // §14.7.3 WhileStatement.
                while (true) {
                    const cc = try self.evalExpr(s.cond, env);
                    if (cc.isAbrupt()) return cc;
                    if (!toBoolean(cc.normal)) break;
                    const bc = try self.evalStmt(s.body.*, env);
                    switch (bc) {
                        .normal, .cont => {},
                        .brk => break,
                        .ret, .throw => return bc,
                    }
                }
                return .{ .normal = .undefined };
            },
            .for_stmt => |s| {
                // §14.7.4 ForStatement — loop bindings in a fresh scope.
                const loop_env = try Environment.create(self.arena, env);
                if (s.init) |i| {
                    const ic = try self.evalStmt(i.*, loop_env);
                    if (ic.isAbrupt()) return ic;
                }
                while (true) {
                    if (s.cond) |t| {
                        const tc = try self.evalExpr(t, loop_env);
                        if (tc.isAbrupt()) return tc;
                        if (!toBoolean(tc.normal)) break;
                    }
                    const bc = try self.evalStmt(s.body.*, loop_env);
                    switch (bc) {
                        .normal, .cont => {}, // continue falls through to the update
                        .brk => break,
                        .ret, .throw => return bc,
                    }
                    if (s.update) |u| {
                        const uc = try self.evalExpr(u, loop_env);
                        if (uc.isAbrupt()) return uc;
                    }
                }
                return .{ .normal = .undefined };
            },
            .throw_stmt => |e| {
                // §14.14 ThrowStatement.
                const c = try self.evalExpr(e, env);
                if (c.isAbrupt()) return c;
                return .{ .throw = c.normal };
            },
            .try_stmt => |s| {
                // §14.15 TryStatement — catch handles a throw; finally's abrupt completion wins.
                var result = try self.runBlock(s.block, try Environment.create(self.arena, env));
                if (result == .throw and s.catch_block != null) {
                    const catch_env = try Environment.create(self.arena, env);
                    if (s.catch_param) |p| try catch_env.declare(p, result.throw, true, true);
                    result = try self.runBlock(s.catch_block.?, catch_env);
                }
                if (s.finally_block) |fb| {
                    const fc = try self.runBlock(fb, try Environment.create(self.arena, env));
                    if (fc.isAbrupt()) return fc;
                }
                return result;
            },
            .break_stmt => return .brk,
            .continue_stmt => return .cont,
            .switch_stmt => |s| {
                // §14.12 SwitchStatement — match by ===, fall through, `break` exits.
                const dc = try self.evalExpr(s.discriminant, env);
                if (dc.isAbrupt()) return dc;
                const sw_env = try Environment.create(self.arena, env);
                var matched = false;
                // First pass: case clauses in order. Second pass (if no match): from default.
                var pass: u8 = 0;
                while (pass < 2) : (pass += 1) {
                    for (s.cases) |case| {
                        if (!matched) {
                            if (pass == 0) {
                                if (case.test_expr) |te| {
                                    const tc = try self.evalExpr(te, sw_env);
                                    if (tc.isAbrupt()) return tc;
                                    if (!strictEquals(dc.normal, tc.normal)) continue;
                                } else continue; // skip default on pass 0
                            } else {
                                if (case.test_expr != null) continue; // pass 1: only start at default
                            }
                            matched = true;
                        }
                        const bc = try self.runBlock(case.body, sw_env);
                        switch (bc) {
                            .normal => {},
                            .brk => return .{ .normal = .undefined },
                            .ret, .throw, .cont => return bc,
                        }
                    }
                    if (matched) break;
                }
                return .{ .normal = .undefined };
            },
        }
    }

    fn runBlock(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!Completion {
        var last: Completion = .{ .normal = .undefined };
        for (stmts) |s| {
            last = try self.evalStmt(s, env);
            if (last.isAbrupt()) return last;
        }
        return last;
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
            .array_literal => |elems| {
                // §13.2.4 ArrayLiteral
                const arr = try Object.createArray(self.arena, self.arrayProto());
                for (elems) |e| {
                    const c = try self.evalExpr(e, env);
                    if (c.isAbrupt()) return c;
                    try arr.elements.append(self.arena, c.normal);
                }
                return .{ .normal = .{ .object = arr } };
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
            .function => |f| return self.evalFunctionExpr(f, env),
            .call => |c| return self.evalCall(c, env),
            .new_expr => |n| return self.evalNew(n, env),
            .logical => |l| {
                // §13.13 short-circuit: `||` returns left if truthy, `&&` returns left if falsy.
                const lc = try self.evalExpr(l.left, env);
                if (lc.isAbrupt()) return lc;
                const truthy = toBoolean(lc.normal);
                switch (l.op) {
                    .or_ => if (truthy) return lc,
                    .and_ => if (!truthy) return lc,
                }
                return self.evalExpr(l.right, env);
            },
            .conditional => |c| {
                // §13.14 cond ? then : otherwise
                const cc = try self.evalExpr(c.cond, env);
                if (cc.isAbrupt()) return cc;
                return self.evalExpr(if (toBoolean(cc.normal)) c.then else c.otherwise, env);
            },
            .update => |u| {
                // §13.4 ++/-- : read target → ToNumber → ±1 → write back; yield old (postfix) or new (prefix).
                const delta: f64 = if (u.op == .inc) 1 else -1;
                switch (u.target.*) {
                    .identifier => |name| {
                        const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                        const old = toNumber(b.value);
                        b.value = .{ .number = old + delta };
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .member => |m| {
                        const oc = try self.evalExpr(m.object, env);
                        if (oc.isAbrupt()) return oc;
                        const cur = try self.getProperty(oc.normal, m.name);
                        if (cur.isAbrupt()) return cur;
                        const old = toNumber(cur.normal);
                        const sc = try self.setProperty(oc.normal, m.name, .{ .number = old + delta });
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .index => |ix| {
                        const oc = try self.evalExpr(ix.object, env);
                        if (oc.isAbrupt()) return oc;
                        const kc = try self.evalExpr(ix.key, env);
                        if (kc.isAbrupt()) return kc;
                        const key = try self.toString(kc.normal);
                        const cur = try self.getProperty(oc.normal, key);
                        if (cur.isAbrupt()) return cur;
                        const old = toNumber(cur.normal);
                        const sc = try self.setProperty(oc.normal, key, .{ .number = old + delta });
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    else => return self.throwError("SyntaxError", "Invalid update expression target"),
                }
            },
            .this => return .{ .normal = self.this_val },
        }
    }

    /// §13.3.5 new — construct an object proto-linked to the constructor's `.prototype`, run
    /// the body with `this` = the new object; if the body returns an object, use it instead.
    fn evalNew(self: *Interpreter, n: anytype, env: *Environment) EvalError!Completion {
        const cc = try self.evalExpr(n.callee, env);
        if (cc.isAbrupt()) return cc;
        if (cc.normal != .object or cc.normal.object.kind != .function) {
            return self.throwError("TypeError", "value is not a constructor");
        }
        const ctor = cc.normal.object;
        var proto: ?*Object = null;
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) proto = pv.object;
        }
        const new_obj = try Object.create(self.arena, proto);

        var args: std.ArrayList(Value) = .empty;
        for (n.args) |arg| {
            const ac = try self.evalExpr(arg, env);
            if (ac.isAbrupt()) return ac;
            try args.append(self.arena, ac.normal);
        }

        const result = try self.callFunction(ctor, args.items, .{ .object = new_obj });
        if (result.isAbrupt()) return result;
        if (result.normal == .object) return .{ .normal = result.normal }; // explicit object return wins
        return .{ .normal = .{ .object = new_obj } };
    }

    fn evalFunctionExpr(self: *Interpreter, f: *const ast.Function, env: *Environment) EvalError!Completion {
        const obj = try Object.createFunction(self.arena, .{ .params = f.params, .body = f.body, .closure = env });
        return .{ .normal = .{ .object = obj } };
    }

    /// §13.3.6 Call. Resolves the callee (with `this` for method calls), evaluates arguments,
    /// then invokes [[Call]].
    fn evalCall(self: *Interpreter, c: anytype, env: *Environment) EvalError!Completion {
        var this_for_call: Value = .undefined;
        var callee: Value = .undefined;
        switch (c.callee.*) {
            .member => |m| {
                const oc = try self.evalExpr(m.object, env);
                if (oc.isAbrupt()) return oc;
                this_for_call = oc.normal;
                const got = try self.getProperty(oc.normal, m.name);
                if (got.isAbrupt()) return got;
                callee = got.normal;
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env);
                if (oc.isAbrupt()) return oc;
                this_for_call = oc.normal;
                const kc = try self.evalExpr(ix.key, env);
                if (kc.isAbrupt()) return kc;
                const got = try self.getProperty(oc.normal, try self.toString(kc.normal));
                if (got.isAbrupt()) return got;
                callee = got.normal;
            },
            else => {
                const cc = try self.evalExpr(c.callee, env);
                if (cc.isAbrupt()) return cc;
                callee = cc.normal;
            },
        }

        var args: std.ArrayList(Value) = .empty;
        for (c.args) |arg| {
            const ac = try self.evalExpr(arg, env);
            if (ac.isAbrupt()) return ac;
            try args.append(self.arena, ac.normal);
        }

        if (callee != .object or callee.object.kind != .function) {
            return self.throwError("TypeError", "value is not a function");
        }
        return self.callFunction(callee.object, args.items, this_for_call);
    }

    /// §10.2.1 [[Call]] — native built-in, else an ordinary AST-closure function.
    pub fn callFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        if (func.native != .none) return self.callNative(func, args, this_val);
        // Each call stacks several heavy native frames — count call depth too so the guard
        // fires before the native stack overflows (these frames are bigger than expr frames).
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > self.max_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
        const fd = func.call orelse return self.throwError("TypeError", "value is not a function");
        const call_env = try Environment.create(self.arena, fd.closure);
        for (fd.params, 0..) |param, i| {
            const v: Value = if (i < args.len) args[i] else .undefined; // missing args → undefined
            try call_env.declare(param, v, true, true);
        }
        const saved_this = self.this_val;
        self.this_val = this_val;
        defer self.this_val = saved_this;

        for (fd.body) |stmt| {
            const c = try self.evalStmt(stmt, call_env);
            switch (c) {
                .normal => {},
                .ret => |v| return .{ .normal = v },
                .throw => return c,
                .brk, .cont => {}, // not produced inside a function body in M1
            }
        }
        return .{ .normal = .undefined }; // implicit return
    }

    /// §10.1.8 [[Get]]. Property access on null/undefined throws (§13.3); other primitives
    /// have no own properties in M1 (no boxing yet) → undefined.
    fn getProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(o.elements.items.len) } };
                    if (parseIndex(key)) |i| {
                        return .{ .normal = if (i < o.elements.items.len) o.elements.items[i] else .undefined };
                    }
                    // else fall through to the prototype chain (Array.prototype methods)
                }
                return .{ .normal = o.get(key) orelse .undefined };
            },
            .string => |s| {
                // §22.1: transparent boxing — `.length`, integer index, or a String.prototype method.
                if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(s.len) } };
                if (parseIndex(key)) |i| {
                    return .{ .normal = if (i < s.len) .{ .string = s[i .. i + 1] } else .undefined };
                }
                if (self.stringProto()) |proto| {
                    if (proto.get(key)) |m| return .{ .normal = m };
                }
                return .{ .normal = .undefined };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot read properties of null or undefined"),
            else => return .{ .normal = .undefined },
        }
    }

    pub fn stringProto(self: *Interpreter) ?*Object {
        return self.globalProto("String");
    }

    /// §10.1.9 [[Set]]. Setting on null/undefined throws; on other primitives is a no-op in M1.
    fn setProperty(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) {
                        const n = toNumber(value);
                        const new_len: usize = if (n >= 0 and n < 1e9) @intFromFloat(n) else o.elements.items.len;
                        if (new_len < o.elements.items.len) {
                            o.elements.shrinkRetainingCapacity(new_len);
                        } else {
                            while (o.elements.items.len < new_len) try o.elements.append(o.arena, .undefined);
                        }
                        return .{ .normal = value };
                    }
                    if (parseIndex(key)) |i| {
                        while (o.elements.items.len <= i) try o.elements.append(o.arena, .undefined);
                        o.elements.items[i] = value;
                        return .{ .normal = value };
                    }
                }
                try o.set(key, value);
                return .{ .normal = value };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot set properties of null or undefined"),
            else => return .{ .normal = value },
        }
    }

    fn evalUnary(self: *Interpreter, op: ast.UnaryOp, operand: *const ast.Node, env: *Environment) EvalError!Completion {
        if (op == .typeof_) {
            // §13.5.3: typeof of an *unresolved* identifier is "undefined" — it must NOT throw
            // (this is how assert.js probes `typeof JSON !== "undefined"`).
            if (operand.* == .identifier and env.lookup(operand.identifier) == null) {
                return .{ .normal = .{ .string = "undefined" } };
            }
            const c = try self.evalExpr(operand, env);
            if (c.isAbrupt()) return c;
            return .{ .normal = .{ .string = typeOf(c.normal) } };
        }
        const c = try self.evalExpr(operand, env);
        if (c.isAbrupt()) return c;
        const v = c.normal;
        return switch (op) {
            .plus => .{ .normal = .{ .number = toNumber(v) } }, // §13.5.4
            .minus => .{ .normal = .{ .number = -toNumber(v) } }, // §13.5.5
            .not => .{ .normal = .{ .boolean = !toBoolean(v) } }, // §13.5.7
            .bit_not => .{ .normal = .{ .number = @floatFromInt(~ops.toInt32(v)) } }, // §13.5.6
            .typeof_ => unreachable,
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
            .exp => return .{ .normal = .{ .number = std.math.pow(f64, toNumber(l), toNumber(r)) } }, // §13.6
            .bit_and => return .{ .normal = .{ .number = @floatFromInt(ops.toInt32(l) & ops.toInt32(r)) } }, // §13.12
            .bit_or => return .{ .normal = .{ .number = @floatFromInt(ops.toInt32(l) | ops.toInt32(r)) } },
            .bit_xor => return .{ .normal = .{ .number = @floatFromInt(ops.toInt32(l) ^ ops.toInt32(r)) } },
            .shl => { // §13.9 — wrap via u32, result is int32
                const sh: u5 = @intCast(ops.toUint32(r) & 31);
                const res: i32 = @bitCast(ops.toUint32(l) << sh);
                return .{ .normal = .{ .number = @floatFromInt(res) } };
            },
            .shr => { // arithmetic (sign-propagating)
                const sh: u5 = @intCast(ops.toUint32(r) & 31);
                return .{ .normal = .{ .number = @floatFromInt(ops.toInt32(l) >> sh) } };
            },
            .shr_un => { // logical (zero-fill), result is uint32
                const sh: u5 = @intCast(ops.toUint32(r) & 31);
                return .{ .normal = .{ .number = @floatFromInt(ops.toUint32(l) >> sh) } };
            },
            .in_op => { // §13.10.2 `key in obj`
                if (r != .object) return self.throwError("TypeError", "Cannot use 'in' operator to search in a non-object");
                const key = try self.toString(l);
                const o = r.object;
                const has = blk: {
                    if (o.kind == .array) {
                        if (std.mem.eql(u8, key, "length")) break :blk true;
                        if (parseIndex(key)) |i| break :blk i < o.elements.items.len;
                    }
                    break :blk o.get(key) != null;
                };
                return .{ .normal = .{ .boolean = has } };
            },
            .lt => return .{ .normal = .{ .boolean = relational(l, r, .lt) } },
            .gt => return .{ .normal = .{ .boolean = relational(l, r, .gt) } },
            .le => return .{ .normal = .{ .boolean = relational(l, r, .le) } },
            .ge => return .{ .normal = .{ .boolean = relational(l, r, .ge) } },
            .instanceof_ => return .{ .normal = .{ .boolean = instanceOf(l, r) } },
            .eq => return .{ .normal = .{ .boolean = looseEquals(l, r) } },
            .ne => return .{ .normal = .{ .boolean = !looseEquals(l, r) } },
            .seq => return .{ .normal = .{ .boolean = strictEquals(l, r) } },
            .sne => return .{ .normal = .{ .boolean = !strictEquals(l, r) } },
        }
    }

    /// §20.5: throw a real Error object carrying `name`/`message`, proto-linked to the realm's
    /// matching Error constructor (so `e instanceof TypeError` and name-based classification work).
    pub fn throwError(self: *Interpreter, kind: []const u8, msg: []const u8) EvalError!Completion {
        const err = try Object.create(self.arena, self.errorProto(kind));
        try err.set("name", .{ .string = kind });
        try err.set("message", .{ .string = msg });
        return .{ .throw = .{ .object = err } };
    }

    fn errorProto(self: *Interpreter, kind: []const u8) ?*Object {
        return self.globalProto(kind);
    }

    /// The `.prototype` object of a named global constructor (Error/Array/…), or null.
    fn globalProto(self: *Interpreter, name: []const u8) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup(name) orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("prototype") orelse return null;
        return if (pv == .object) pv.object else null;
    }

    pub fn arrayProto(self: *Interpreter) ?*Object {
        return self.globalProto("Array");
    }

    /// Dispatch a built-in function (§19/§20). Behavior keyed by `func.native`.
    fn callNative(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        switch (func.native) {
            .array_ctor => {
                const arr = try Object.createArray(self.arena, self.arrayProto());
                for (args) |a| try arr.elements.append(self.arena, a);
                return .{ .normal = .{ .object = arr } };
            },
            .array_method => return builtin_array.call(self, func.native_name, this_val, args),
            .string_method => return builtin_string.call(self, func.native_name, this_val, args),
            else => {},
        }
        switch (func.native) {
            .error_ctor => {
                const proto: ?*Object = blk: {
                    const pv = func.get("prototype") orelse break :blk null;
                    break :blk if (pv == .object) pv.object else null;
                };
                const err = try Object.create(self.arena, proto);
                try err.set("name", .{ .string = func.native_name });
                const msg: Value = if (args.len > 0 and args[0] != .undefined)
                    .{ .string = try self.toString(args[0]) }
                else
                    .{ .string = "" };
                try err.set("message", msg);
                return .{ .normal = .{ .object = err } };
            },
            .string_ctor => {
                const v: Value = if (args.len > 0) args[0] else .undefined;
                return .{ .normal = .{ .string = try self.toString(v) } };
            },
            .object_ctor => {
                if (args.len > 0 and args[0] == .object) return .{ .normal = args[0] };
                return .{ .normal = .{ .object = try Object.create(self.arena, null) } };
            },
            .object_to_string => return .{ .normal = .{ .string = "[object Object]" } },
            .array_ctor, .array_method, .string_method => unreachable, // handled in the first switch
            .none => unreachable,
        }
    }

    /// §7.1.17 ToString (subset; primitives only).
    /// §7.1.17 ToString — delegates to the abstract operation (handles Array join).
    pub fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
        return ops.toString(self.arena, v);
    }
};
