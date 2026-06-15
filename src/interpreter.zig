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
                const mutable = d.kind != .const_decl;
                for (d.decls) |dec| {
                    var v: Value = .undefined;
                    if (dec.init) |ie| {
                        const c = try self.evalExpr(ie, env);
                        if (c.isAbrupt()) return c;
                        v = c.normal;
                    }
                    // Fast path: a plain `var x = …` binds directly, skipping pattern matching so
                    // the common case pays no destructuring cost (perf gate).
                    if (dec.target.* == .identifier) {
                        try env.declare(dec.target.identifier, v, mutable, true);
                    } else {
                        const bc = try self.bindPattern(dec.target, v, env, mutable);
                        if (bc.isAbrupt()) return bc;
                    }
                }
                return .{ .normal = .undefined };
            },
            .block => |stmts| {
                // §14.2 Block. Allocate a child scope only when the block actually has lexical
                // declarations (let/const/function); declaration-free blocks (e.g. hot loop
                // bodies) reuse the parent env — avoids a per-iteration allocation.
                if (blockNeedsScope(stmts)) return self.runBlock(stmts, try Environment.create(self.arena, env));
                return self.runBlock(stmts, env);
            },
            .func_decl => |f| {
                // §15.2 — bind a function object to its name in the current scope.
                const obj = try Object.createFunction(self.arena, .{ .params = f.params, .rest = f.rest, .body = f.body, .closure = env });
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
            .comma => |c| {
                // §13.16.1 Expression : Expression `,` AssignmentExpression — evaluate the left
                // operand for its side effects (discarding its value via GetValue), then evaluate and
                // yield the right operand.
                const lc = try self.evalExpr(c.left, env);
                if (lc.isAbrupt()) return lc;
                return self.evalExpr(c.right, env);
            },
            .binary => |b| return self.evalBinary(b.op, b.left, b.right, env),
            .object_literal => |props| return self.evalObjectLiteral(props, env),
            .array_literal => |elems| {
                // §13.2.4 ArrayLiteral — `...spread` elements flatten in place.
                const arr = try Object.createArray(self.arena, self.arrayProto());
                const lc = try self.evalSpreadList(elems, env, &arr.elements);
                if (lc.isAbrupt()) return lc;
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
                // §13.13 short-circuit: `||` returns left if truthy, `&&` returns left if falsy,
                // `??` returns left unless it is null/undefined (then the right operand).
                const lc = try self.evalExpr(l.left, env);
                if (lc.isAbrupt()) return lc;
                switch (l.op) {
                    .or_ => if (toBoolean(lc.normal)) return lc,
                    .and_ => if (!toBoolean(lc.normal)) return lc,
                    .coalesce => if (lc.normal != .undefined and lc.normal != .null) return lc,
                }
                return self.evalExpr(l.right, env);
            },
            .logical_assign => |la| return self.evalLogicalAssign(la, env),
            .optional => return self.evalOptionalChain(node, env),
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
            .template => |t| {
                // §13.2.8 — concatenate quasis with ToString of each substitution.
                var buf: std.ArrayList(u8) = .empty;
                for (t.quasis, 0..) |q, idx| {
                    try buf.appendSlice(self.arena, q);
                    if (idx < t.exprs.len) {
                        const c = try self.evalExpr(t.exprs[idx], env);
                        if (c.isAbrupt()) return c;
                        try buf.appendSlice(self.arena, try self.toString(c.normal));
                    }
                }
                return .{ .normal = .{ .string = buf.items } };
            },
            .this => return .{ .normal = self.this_val },
            .spread => return self.throwError("SyntaxError", "Unexpected token '...'"), // only valid in array/call/new lists
        }
    }

    /// §13.15.2 LogicalAssignment `&&=` / `||=` / `??=`. Short-circuit, evaluating the target
    /// reference EXACTLY ONCE: resolve the reference (binding, or base [+ key] for member/index),
    /// read the current value, let the guard decide, and only then evaluate the RHS and write.
    ///   • `&&=` assigns only when the current value is truthy.
    ///   • `||=` assigns only when the current value is falsy.
    ///   • `??=` assigns only when the current value is null/undefined (§13.13 nullish, from Cycle 6).
    /// Yields the final value of the target (the RHS when assigned, else the unchanged value).
    fn evalLogicalAssign(self: *Interpreter, la: anytype, env: *Environment) EvalError!Completion {
        switch (la.target.*) {
            .identifier => |name| {
                const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                if (!b.initialized) return self.throwError("ReferenceError", name); // TDZ
                if (!shouldAssign(la.op, b.value)) return .{ .normal = b.value };
                const rc = try self.evalExpr(la.value, env);
                if (rc.isAbrupt()) return rc;
                if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                b.value = rc.normal;
                return .{ .normal = rc.normal };
            },
            .member => |m| {
                const oc = try self.evalExpr(m.object, env); // base evaluated once
                if (oc.isAbrupt()) return oc;
                const cur = try self.getProperty(oc.normal, m.name);
                if (cur.isAbrupt()) return cur;
                if (!shouldAssign(la.op, cur.normal)) return cur;
                const rc = try self.evalExpr(la.value, env);
                if (rc.isAbrupt()) return rc;
                return self.setProperty(oc.normal, m.name, rc.normal);
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env); // base evaluated once
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env); // key evaluated once
                if (kc.isAbrupt()) return kc;
                const key = try self.toString(kc.normal);
                const cur = try self.getProperty(oc.normal, key);
                if (cur.isAbrupt()) return cur;
                if (!shouldAssign(la.op, cur.normal)) return cur;
                const rc = try self.evalExpr(la.value, env);
                if (rc.isAbrupt()) return rc;
                return self.setProperty(oc.normal, key, rc.normal);
            },
            else => return self.throwError("SyntaxError", "Invalid assignment target"),
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
        // §15.3: arrow functions have no [[Construct]] — `new (() => {})` is a TypeError.
        if (ctor.call) |fd| {
            if (fd.is_arrow) return self.throwError("TypeError", "value is not a constructor");
        }
        var proto: ?*Object = null;
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) proto = pv.object;
        }
        const new_obj = try Object.create(self.arena, proto);

        var args: std.ArrayListUnmanaged(Value) = .empty;
        const alc = try self.evalSpreadList(n.args, env, &args);
        if (alc.isAbrupt()) return alc;

        const result = try self.callFunction(ctor, args.items, .{ .object = new_obj });
        if (result.isAbrupt()) return result;
        if (result.normal == .object) return .{ .normal = result.normal }; // explicit object return wins
        return .{ .normal = .{ .object = new_obj } };
    }

    /// §13.2.5 ObjectLiteral evaluation — a fresh ordinary object (proto-linked to Object.prototype
    /// when available). Walks PropertyDefinitions in order: data `k:v` / shorthand / method, computed
    /// keys, accessors (`get`/`set` → `defineAccessor`), and `...spread` (CopyDataProperties).
    fn evalObjectLiteral(self: *Interpreter, props: []const ast.Property, env: *Environment) EvalError!Completion {
        const obj = try Object.create(self.arena, self.globalProto("Object"));
        for (props) |p| {
            switch (p.kind) {
                .spread => {
                    // §13.2.5.4 CopyDataProperties — copy own enumerable props of the source. Null /
                    // undefined sources are ignored (no throw); arrays spread their indices + length-
                    // independent own props.
                    const sc = try self.evalExpr(p.value, env);
                    if (sc.isAbrupt()) return sc;
                    try self.copyDataProperties(obj, sc.normal);
                },
                .get, .set => {
                    const key = try self.propKey(p, env);
                    if (key.isAbrupt()) return key.completion;
                    const fc = try self.evalExpr(p.value, env);
                    if (fc.isAbrupt()) return fc;
                    const f = fc.normal.object; // a `function` node always yields a function object
                    if (p.kind == .get) {
                        try obj.defineAccessor(key.key, f, null);
                    } else {
                        try obj.defineAccessor(key.key, null, f);
                    }
                },
                .init => {
                    const key = try self.propKey(p, env);
                    if (key.isAbrupt()) return key.completion;
                    const c = try self.evalExpr(p.value, env);
                    if (c.isAbrupt()) return c;
                    try obj.set(key.key, c.normal);
                },
            }
        }
        return .{ .normal = .{ .object = obj } };
    }

    const KeyResult = struct {
        key: []const u8 = "",
        completion: Completion = .{ .normal = .undefined },
        fn isAbrupt(self: KeyResult) bool {
            return self.completion.isAbrupt();
        }
    };

    /// Resolve a PropertyDefinition's key: a computed `[expr]` (evaluated + ToString'd) or the
    /// static identifier/string/numeric key parsed earlier.
    fn propKey(self: *Interpreter, p: ast.Property, env: *Environment) EvalError!KeyResult {
        if (p.computed_key) |ck| {
            const c = try self.evalExpr(ck, env);
            if (c.isAbrupt()) return .{ .completion = c };
            return .{ .key = try self.toString(c.normal) };
        }
        return .{ .key = p.key };
    }

    /// §7.3.25 CopyDataProperties — copy `source`'s own enumerable data properties into `target`
    /// (invoking getters to read the values). Null/undefined sources are no-ops. Used by object
    /// spread `{...source}`.
    fn copyDataProperties(self: *Interpreter, target: *Object, source: Value) EvalError!void {
        switch (source) {
            .undefined, .null => return,
            .object => |o| {
                if (o.kind == .array) {
                    for (o.elements.items, 0..) |el, i| {
                        const k = try self.toString(.{ .number = @floatFromInt(i) });
                        try target.set(k, el);
                    }
                }
                var it = o.properties.iterator();
                while (it.next()) |entry| {
                    const gc = try self.getProperty(source, entry.key_ptr.*);
                    if (gc.isAbrupt()) return; // a throwing getter aborts copy (best-effort here)
                    try target.set(entry.key_ptr.*, gc.normal);
                }
            },
            .string => |s| {
                // Strings spread their index properties + length (own enumerable: the indices).
                for (0..s.len) |i| {
                    const k = try self.toString(.{ .number = @floatFromInt(i) });
                    try target.set(k, .{ .string = s[i .. i + 1] });
                }
            },
            else => return,
        }
    }

    /// §13.3.9 Optional chain evaluation — a thin wrapper returning the chain's value (the receiver
    /// is only needed internally for `?.( )` calls). A short-circuit yields `undefined`.
    fn evalOptionalChain(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!Completion {
        const r = try self.evalChain(node, env);
        if (r.isAbrupt()) return r.completion;
        return .{ .normal = r.value };
    }

    const ChainResult = struct {
        value: Value = .undefined,
        this_val: Value = .undefined, // receiver to use if the *next* link is a call
        short: bool = false, // the chain short-circuited (a `?.` base was nullish)
        completion: Completion = .{ .normal = .undefined },
        fn isAbrupt(self: ChainResult) bool {
            return self.completion.isAbrupt();
        }
    };

    /// Walk one access link of an optional chain. `node` is either an `.optional` link (whose base
    /// is the rest of the chain) or any other expression (the chain root). Returns the produced
    /// value, the receiver for a following call, and whether the chain short-circuited.
    fn evalChain(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!ChainResult {
        if (node.* != .optional) {
            // Chain root: an ordinary (possibly member/call) expression.
            const c = try self.evalExpr(node, env);
            if (c.isAbrupt()) return .{ .completion = c };
            return .{ .value = c.normal };
        }
        const opt = node.optional;
        const base = try self.evalChain(opt.base, env);
        if (base.isAbrupt()) return base;
        if (base.short) return .{ .short = true }; // §13.3.9.1: propagate the short-circuit
        // §13.3.9.1: a `?.` link whose base is null/undefined short-circuits the WHOLE chain.
        if (opt.optional and (base.value == .undefined or base.value == .null)) {
            return .{ .short = true };
        }
        switch (opt.link) {
            .member => |name| {
                const gc = try self.getProperty(base.value, name);
                if (gc.isAbrupt()) return .{ .completion = gc };
                return .{ .value = gc.normal, .this_val = base.value };
            },
            .index => |key_node| {
                const kc = try self.evalExpr(key_node, env);
                if (kc.isAbrupt()) return .{ .completion = kc };
                const gc = try self.getProperty(base.value, try self.toString(kc.normal));
                if (gc.isAbrupt()) return .{ .completion = gc };
                return .{ .value = gc.normal, .this_val = base.value };
            },
            .call => |arg_nodes| {
                // §13.3.6: the callee is `base.value`; `this` is the receiver carried from the
                // previous member/index link (undefined for a bare `a?.()`).
                var args: std.ArrayListUnmanaged(Value) = .empty;
                const alc = try self.evalSpreadList(arg_nodes, env, &args);
                if (alc.isAbrupt()) return .{ .completion = alc };
                if (base.value != .object or base.value.object.kind != .function) {
                    return .{ .completion = try self.throwError("TypeError", "value is not a function") };
                }
                const rc = try self.callFunction(base.value.object, args.items, base.this_val);
                if (rc.isAbrupt()) return .{ .completion = rc };
                return .{ .value = rc.normal };
            },
        }
    }

    fn evalFunctionExpr(self: *Interpreter, f: *const ast.Function, env: *Environment) EvalError!Completion {
        // §15.3: an arrow captures the enclosing `this` at creation time (lexical `this`); an
        // ordinary function gets `this` bound per-call instead.
        const obj = try Object.createFunction(self.arena, .{
            .params = f.params,
            .rest = f.rest,
            .body = f.body,
            .closure = env,
            .is_arrow = f.is_arrow,
            .captured_this = if (f.is_arrow) self.this_val else .undefined,
        });
        return .{ .normal = .{ .object = obj } };
    }

    /// Evaluate an argument / element list into `out`, flattening `...expr` spread elements
    /// (§13.2.4 / §13.3 — arrays spread their elements, strings their characters). Returns an
    /// abrupt completion to propagate, else `.{ .normal = .undefined }`.
    fn evalSpreadList(self: *Interpreter, nodes: []const *const ast.Node, env: *Environment, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
        for (nodes) |n| {
            if (n.* == .spread) {
                const sc = try self.evalExpr(n.spread, env);
                if (sc.isAbrupt()) return sc;
                switch (sc.normal) {
                    .object => |o| {
                        if (o.kind != .array) return self.throwError("TypeError", "spread target is not iterable");
                        for (o.elements.items) |el| try out.append(self.arena, el);
                    },
                    .string => |s| for (s, 0..) |_, i| try out.append(self.arena, .{ .string = s[i .. i + 1] }),
                    else => return self.throwError("TypeError", "spread target is not iterable"),
                }
            } else {
                const c = try self.evalExpr(n, env);
                if (c.isAbrupt()) return c;
                try out.append(self.arena, c.normal);
            }
        }
        return .{ .normal = .undefined };
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

        var args: std.ArrayListUnmanaged(Value) = .empty;
        const alc = try self.evalSpreadList(c.args, env, &args);
        if (alc.isAbrupt()) return alc;

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
            var v: Value = if (i < args.len) args[i] else .undefined; // missing args → undefined
            if (v == .undefined) {
                if (param.default) |dn| { // §15.1 default value applied when the arg is undefined
                    const dc = try self.evalExpr(dn, call_env);
                    if (dc.isAbrupt()) return dc;
                    v = dc.normal;
                }
            }
            // Fast path: a plain identifier parameter binds directly (no pattern matching).
            if (param.pattern.* == .identifier) {
                try call_env.declare(param.pattern.identifier, v, true, true);
            } else {
                const bc = try self.bindPattern(param.pattern, v, call_env, true);
                if (bc.isAbrupt()) return bc;
            }
        }
        if (fd.rest) |rest_pat| {
            // §15.1 rest parameter — bind leftover args (beyond the fixed params) as an Array,
            // then destructure that Array into the rest pattern (commonly a single identifier).
            const rest_arr = try Object.createArray(self.arena, self.arrayProto());
            if (args.len > fd.params.len) {
                for (args[fd.params.len..]) |a| try rest_arr.elements.append(self.arena, a);
            }
            if (rest_pat.* == .identifier) {
                try call_env.declare(rest_pat.identifier, .{ .object = rest_arr }, true, true);
            } else {
                const bc = try self.bindPattern(rest_pat, .{ .object = rest_arr }, call_env, true);
                if (bc.isAbrupt()) return bc;
            }
        }
        // §15.3: an arrow has no own `this` binding — it uses the `this` captured at creation,
        // ignoring however it was called. Ordinary functions take the call-site `this`.
        const saved_this = self.this_val;
        self.this_val = if (fd.is_arrow) fd.captured_this else this_val;
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

    /// §8.6.2 BindingInitialization / §13.15.5.2 — destructure `value` into the bindings of
    /// `pattern`, declaring each leaf binding in `env`. Used by both declarations (§14.3) and
    /// parameter binding (§15.1). `mutable` is false for `const` targets.
    fn bindPattern(self: *Interpreter, pattern: *const ast.Pattern, value: Value, env: *Environment, mutable: bool) EvalError!Completion {
        switch (pattern.*) {
            .identifier => |name| {
                // §8.6.2 single-name binding — InitializeBoundName.
                try env.declare(name, value, mutable, true);
                return .{ .normal = .undefined };
            },
            .array => |ap| {
                // §13.15.5.3 ArrayBindingPattern: pull values positionally from an iterable.
                // We support Arrays and Strings as iterables (matching the engine's spread model).
                const items = try self.iterableToSlice(value);
                if (items == null) return self.throwError("TypeError", "value is not iterable");
                const slice = items.?;
                for (ap.elements, 0..) |el, i| {
                    if (el.target == null) continue; // elision / hole — skip this position
                    var v: Value = if (i < slice.len) slice[i] else .undefined;
                    if (v == .undefined) {
                        if (el.default) |dn| { // §8.6.2 apply the `= default` when undefined
                            const dc = try self.evalExpr(dn, env);
                            if (dc.isAbrupt()) return dc;
                            v = dc.normal;
                        }
                    }
                    const bc = try self.bindPattern(el.target.?, v, env, mutable);
                    if (bc.isAbrupt()) return bc;
                }
                if (ap.rest) |rest_pat| {
                    // §13.15.5.3 BindingRestElement — leftover items become a fresh Array.
                    const rest_arr = try Object.createArray(self.arena, self.arrayProto());
                    if (slice.len > ap.elements.len) {
                        for (slice[ap.elements.len..]) |a| try rest_arr.elements.append(self.arena, a);
                    }
                    const bc = try self.bindPattern(rest_pat, .{ .object = rest_arr }, env, mutable);
                    if (bc.isAbrupt()) return bc;
                }
                return .{ .normal = .undefined };
            },
            .object => |op| {
                // §13.15.5.5 ObjectBindingPattern — requires a coercible value (§13.15.5.4).
                if (value == .undefined or value == .null) {
                    return self.throwError("TypeError", "Cannot destructure null or undefined");
                }
                for (op.properties) |prop| {
                    const gc = try self.getProperty(value, prop.key);
                    if (gc.isAbrupt()) return gc;
                    var v = gc.normal;
                    if (v == .undefined) {
                        if (prop.default) |dn| {
                            const dc = try self.evalExpr(dn, env);
                            if (dc.isAbrupt()) return dc;
                            v = dc.normal;
                        }
                    }
                    const bc = try self.bindPattern(prop.target, v, env, mutable);
                    if (bc.isAbrupt()) return bc;
                }
                if (op.rest) |rest_name| {
                    // §14.3.3 BindingRestProperty — own enumerable props not already destructured,
                    // copied into a fresh ordinary object (reading via [[Get]], so getters run).
                    const rest_obj = try Object.create(self.arena, null);
                    if (value == .object) {
                        var it = value.object.properties.iterator();
                        while (it.next()) |entry| {
                            const k = entry.key_ptr.*;
                            var taken = false;
                            for (op.properties) |prop| {
                                if (std.mem.eql(u8, prop.key, k)) {
                                    taken = true;
                                    break;
                                }
                            }
                            if (!taken) {
                                const gc = try self.getProperty(value, k);
                                if (gc.isAbrupt()) return gc;
                                try rest_obj.set(k, gc.normal);
                            }
                        }
                    }
                    try env.declare(rest_name, .{ .object = rest_obj }, mutable, true);
                }
                return .{ .normal = .undefined };
            },
        }
    }

    /// Materialize an iterable `value` into a slice of element Values, for array destructuring
    /// (§13.15.5.3 IteratorBindingInitialization). Supports Arrays and Strings (the engine's
    /// iterable model); returns null for non-iterables so the caller can throw a TypeError.
    fn iterableToSlice(self: *Interpreter, value: Value) EvalError!?[]const Value {
        switch (value) {
            .object => |o| {
                if (o.kind != .array) return null;
                return o.elements.items;
            },
            .string => |s| {
                var list: std.ArrayListUnmanaged(Value) = .empty;
                for (0..s.len) |i| try list.append(self.arena, .{ .string = s[i .. i + 1] });
                return list.items;
            },
            else => return null,
        }
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
                // §10.1.8.1 OrdinaryGet — locate the property (data or accessor) on the chain.
                // Data-property fast path: a single descriptor read, no accessor branch.
                const loc = o.getProp(key) orelse return .{ .normal = .undefined };
                switch (loc.pv) {
                    .data => |v| return .{ .normal = v },
                    .accessor => |a| {
                        // §10.2.x: invoke the getter with `this` = the original receiver (`base`).
                        const getter = a.get orelse return .{ .normal = .undefined };
                        return self.callFunction(getter, &.{}, base);
                    },
                }
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
                // §10.1.9.2 OrdinarySetWithOwnDescriptor — if `key` resolves to an accessor on the
                // chain, invoke its setter with `this` = receiver; a getter-only accessor is a silent
                // no-op (sloppy). A data property (own or inherited) → define/overwrite an own data
                // property. The common case (absent or own data) stays a single `set`.
                if (o.getProp(key)) |loc| {
                    if (loc.pv == .accessor) {
                        const setter = loc.pv.accessor.set orelse return .{ .normal = value };
                        const sc = try self.callFunction(setter, &.{value}, base);
                        if (sc.isAbrupt()) return sc;
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
        // §13.5.1.2 `delete` — operates on a Reference, not a value, so resolve the target rather
        // than calling GetValue. A property reference (`a.b` / `a[k]`) deletes the own property and
        // returns true (M-subset: every own property is configurable). A non-Reference operand
        // (`delete 5`, `delete f()`, a parenthesized non-reference) evaluates its operand for side
        // effects and returns true. An unqualified identifier returns true in sloppy mode (we don't
        // yet enforce the §13.5.1.1 strict-mode SyntaxError — see gap note).
        if (op == .delete_) return self.evalDelete(operand, env);
        const c = try self.evalExpr(operand, env);
        if (c.isAbrupt()) return c;
        const v = c.normal;
        return switch (op) {
            .plus => .{ .normal = .{ .number = toNumber(v) } }, // §13.5.4
            .minus => .{ .normal = .{ .number = -toNumber(v) } }, // §13.5.5
            .not => .{ .normal = .{ .boolean = !toBoolean(v) } }, // §13.5.7
            .void_ => .{ .normal = .undefined }, // §13.5.2: evaluate operand (done), yield undefined
            .bit_not => .{ .normal = .{ .number = @floatFromInt(~ops.toInt32(v)) } }, // §13.5.6
            .typeof_, .delete_ => unreachable,
        };
    }

    /// §13.5.1.2 Runtime Semantics of the `delete` UnaryExpression. `delete a.b` / `delete a[k]`
    /// resolves the base object, removes the own property `key`, and returns `true`. For an array
    /// integer index we leave a hole by setting the element to `undefined` (M-subset; a true sparse
    /// array model is deferred). A non-Reference operand evaluates for side effects and returns true.
    fn evalDelete(self: *Interpreter, operand: *const ast.Node, env: *Environment) EvalError!Completion {
        switch (operand.*) {
            .member => |m| {
                const oc = try self.evalExpr(m.object, env);
                if (oc.isAbrupt()) return oc;
                return self.deleteProperty(oc.normal, m.name);
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env);
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env);
                if (kc.isAbrupt()) return kc;
                return self.deleteProperty(oc.normal, try self.toString(kc.normal));
            },
            // §13.5.1.2 step 3: `delete` of an unqualified IdentifierReference. In sloppy mode the
            // binding would be deleted only if configurable; our bindings aren't deletable, so we
            // return true without removing (a benign M-subset deviation). Strict mode is a
            // SyntaxError (§13.5.1.1) — not yet enforced (no strict-mode context; see gap note).
            .identifier => return .{ .normal = .{ .boolean = true } },
            // §13.5.1.2 step 2: the operand is not a Reference — evaluate it for side effects and
            // return true (`delete 5`, `delete f()`, `delete (x + 1)`).
            else => {
                const c = try self.evalExpr(operand, env);
                if (c.isAbrupt()) return c;
                return .{ .normal = .{ .boolean = true } };
            },
        }
    }

    /// Remove the own property `key` from `base`, returning `true` (M-subset: always deletable).
    /// On a primitive base, deletion is a no-op that returns true.
    fn deleteProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.kind == .array) {
                    if (parseIndex(key)) |i| {
                        // M-subset: leave a hole by writing `undefined` (no true sparse-array model).
                        if (i < o.elements.items.len) o.elements.items[i] = .undefined;
                        return .{ .normal = .{ .boolean = true } };
                    }
                }
                _ = o.properties.remove(key);
                return .{ .normal = .{ .boolean = true } };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
            else => return .{ .normal = .{ .boolean = true } },
        }
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

    /// §7.1.17 ToString — delegates to the abstract operation (handles Array join).
    pub fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
        return ops.toString(self.arena, v);
    }
};

/// §13.15.2: should a LogicalAssignment write, given the operator and the target's current value?
///   • `&&=` (and_)      — only when the current value is truthy.
///   • `||=` (or_)       — only when the current value is falsy.
///   • `??=` (coalesce)  — only when the current value is null/undefined (§13.13 nullish guard).
fn shouldAssign(op: ast.LogicalOp, cur: Value) bool {
    return switch (op) {
        .and_ => toBoolean(cur),
        .or_ => !toBoolean(cur),
        .coalesce => cur == .undefined or cur == .null,
    };
}

/// A block needs its own declarative scope only if it lexically declares (let/const/function);
/// `var` is function-scoped and declaration-free blocks can reuse the parent env (hot-loop win).
fn blockNeedsScope(stmts: []const ast.Stmt) bool {
    for (stmts) |s| switch (s) {
        .declaration => |d| if (d.kind != .var_decl) return true,
        .func_decl => return true,
        else => {},
    };
    return false;
}
