//! Tree-walking interpreter (ECMA-262 §13–§14). M1 adds statement evaluation over an
//! Environment chain: declarations (`var`/`let`/`const`), assignment, blocks (lexical scope),
//! the `let`/`const` temporal dead zone, and `const` reassignment errors. Each step mirrors a
//! spec algorithm and carries its clause reference. A step-cap watchdog bounds runaway runs.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const builtin_array = @import("builtin_array.zig");
const builtin_string = @import("builtin_string.zig");
const builtins = @import("builtins.zig");

// ECMA-262 abstract operations live in abstract_ops.zig; alias them so call sites read naturally.
const toNumber = ops.toNumber;
const toBoolean = ops.toBoolean;
const typeOf = ops.typeOf;
const relational = ops.relational;
const strictEquals = ops.strictEquals;
const looseEquals = ops.looseEquals;
const instanceOf = ops.instanceOf;
const parseIndex = ops.parseIndex;
const numberToString = ops.numberToString;

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
    /// §9.2.5 / §13.3.5 the active function's [[HomeObject]] — set when a class/object method is
    /// invoked (to its `home_object`), null otherwise. `super.x` resolves against
    /// `home_object.[[Prototype]]`; `super(...)` invokes `home_object`'s constructor's superclass.
    /// Saved/restored around each [[Call]] alongside `this_val`.
    home_object: ?*Object = null,
    /// The realm's global environment — used to resolve the Error family for engine-thrown
    /// errors (so they carry the right prototype + name). Set by the engine after setup.
    globals: ?*Environment = null,
    /// §27.5 the generator whose body THIS interpreter is currently executing (set on the per-generator
    /// body interpreter spawned for a `function*`; null for the main interpreter and ordinary calls).
    /// A `yield` is legal only when this is non-null; evaluating `yield x` reaches the handoff via it.
    current_gen: ?*object_mod.Generator = null,
    /// All generators created in this realm (tracked on the MAIN interpreter only, via `gen_registry`).
    /// At realm teardown `cleanupGenerators` signals any still-parked body thread to unwind and joins
    /// it, so a never-fully-consumed generator does not leave a lingering OS thread. The body
    /// interpreters share the same registry pointer.
    gen_registry: ?*std.ArrayListUnmanaged(*object_mod.Generator) = null,
    /// The process-global threaded Io — supplies the raw-OS-futex backing `std.Io.Semaphore.wait/post`
    /// for the generator ping-pong handoff. `global_single_threaded` spins up no thread pool (futex ops
    /// are pool-independent), so this is free for ordinary (non-generator) execution.
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),

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
                const obj = try Object.createFunction(self.arena, .{ .params = f.params, .rest = f.rest, .body = f.body, .closure = env, .is_generator = f.is_generator });
                obj.prototype = self.functionProto(); // §20.2.3 so `f.call`/`.apply`/`.bind` resolve
                if (f.name) |name| try env.declare(name, .{ .object = obj }, true, true);
                return .{ .normal = .undefined };
            },
            .class_decl => |c| {
                // §15.7.14 ClassDefinitionEvaluation — build the constructor, then bind the class
                // name in the current (declaration) scope.
                const cc = try self.evalClass(c, env);
                if (cc.isAbrupt()) return cc;
                if (c.name) |name| try env.declare(name, cc.normal, true, true);
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
            .for_in_stmt => |s| return self.evalForIn(s, env),
            .for_of_stmt => |s| return self.evalForOf(s, env),
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

    /// §14.7.5 `for (HEAD in EXPR)` — ForIn/OfHeadEvaluation (enumerate) + ForIn/OfBodyEvaluation.
    fn evalForIn(self: *Interpreter, s: anytype, env: *Environment) EvalError!Completion {
        // §14.7.5.6 step 7.a: a null/undefined operand → the body never runs (no throw).
        const rc = try self.evalExpr(s.right, env);
        if (rc.isAbrupt()) return rc;
        if (rc.normal == .undefined or rc.normal == .null) return .{ .normal = .undefined };
        // EnumerateObjectProperties — the enumerable string keys to visit (computed once up front;
        // mutations to the object during the loop are not reflected, an accepted M-subset simplification).
        var keys: std.ArrayListUnmanaged(Value) = .empty;
        try self.enumerateKeys(rc.normal, &keys);
        for (keys.items) |k| {
            const hb = try self.bindForHead(s.head, k, env);
            if (hb.completion.isAbrupt()) return hb.completion;
            const bc = try self.evalStmt(s.body.*, hb.env);
            switch (bc) {
                .normal, .cont => {},
                .brk => break,
                .ret, .throw => return bc,
            }
        }
        return .{ .normal = .undefined };
    }

    /// §14.7.5 `for (HEAD of EXPR)` — ForIn/OfHeadEvaluation (§7.4.2 GetIterator) + ForIn/OfBodyEvaluation,
    /// driven by the real iterator protocol: `GetIterator(EXPR)`, then per iteration `IteratorStep` →
    /// `IteratorValue` → bind to HEAD → run body, and `IteratorClose` (call `return()`) on an early exit
    /// (`break`/`return`/`throw`). Any object with a `[Symbol.iterator]` works; Arrays/Strings use a fast
    /// native iterator. A non-iterable operand → TypeError.
    fn evalForOf(self: *Interpreter, s: anytype, env: *Environment) EvalError!Completion {
        const rc = try self.evalExpr(s.right, env);
        if (rc.isAbrupt()) return rc;
        const git = try self.getIterator(rc.normal);
        const iterator = switch (git) {
            .abrupt => |c| return c,
            .iterator => |it| it,
        };
        while (true) {
            const step = try self.iteratorStep(iterator);
            const v = switch (step) {
                .abrupt => |c| return c, // a throwing next() — already an abrupt completion
                .done => break,
                .value => |val| val,
            };
            const hb = try self.bindForHead(s.head, v, env);
            if (hb.completion.isAbrupt()) {
                try self.iteratorClose(iterator); // §7.4.11 abrupt binding → close the iterator
                return hb.completion;
            }
            const bc = try self.evalStmt(s.body.*, hb.env);
            switch (bc) {
                .normal, .cont => {},
                .brk => {
                    try self.iteratorClose(iterator); // §14.7.5.7 step 11.b.iii: break closes the iterator
                    break;
                },
                .ret, .throw => {
                    try self.iteratorClose(iterator);
                    return bc;
                },
            }
        }
        return .{ .normal = .undefined };
    }

    const HeadBinding = struct { env: *Environment, completion: Completion = .{ .normal = .undefined } };

    /// §14.7.5.7 ForIn/OfBodyEvaluation: bind/assign one item to the loop head, returning the
    /// environment the body runs in (plus any abrupt completion from an assignment-target write). A
    /// `let`/`const` head gets a FRESH per-iteration `Environment` (CreatePerIterationEnvironment), so
    /// each iteration's binding is independent (closures capture distinct values). A `var` declaration
    /// or an assignment-target head writes into / through `env`.
    fn bindForHead(self: *Interpreter, head: ast.ForHead, item: Value, env: *Environment) EvalError!HeadBinding {
        switch (head) {
            .decl => |d| {
                const mutable = d.kind != .const_decl;
                // §14.7.5.7: let/const create a fresh binding each iteration; var reuses the loop env.
                const target_env = if (d.kind == .var_decl) env else try Environment.create(self.arena, env);
                if (d.target.* == .identifier) {
                    try target_env.declare(d.target.identifier, item, mutable, true);
                } else {
                    const bc = try self.bindPattern(d.target, item, target_env, mutable);
                    if (bc.isAbrupt()) return .{ .env = env, .completion = bc };
                }
                return .{ .env = target_env };
            },
            .target => |t| {
                // §13.15.2 PutValue to an existing reference (identifier / member / index).
                const wc = try self.assignToTarget(t, item, env);
                return .{ .env = env, .completion = if (wc.isAbrupt()) wc else .{ .normal = .undefined } };
            },
        }
    }

    /// §6.2.5.6 PutValue — write `value` through the AssignmentTarget `node` (identifier / `a.b` /
    /// `a[k]`). Mirrors the `assign`/`assign_member`/`assign_index` evaluation paths.
    fn assignToTarget(self: *Interpreter, node: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
        switch (node.*) {
            .identifier => |name| {
                const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                b.value = value;
                return .{ .normal = value };
            },
            .member => |m| {
                const oc = try self.evalExpr(m.object, env);
                if (oc.isAbrupt()) return oc;
                return self.setProperty(oc.normal, m.name, value);
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env);
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env);
                if (kc.isAbrupt()) return kc;
                return self.setPropertyV(oc.normal, kc.normal, value);
            },
            // §13.3.2 `obj.#x` as a destructuring target — write the private slot (TypeError if `obj`
            // lacks the brand). The `=` was not folded here (no default), so the node is `private_member`.
            .private_member => |pm| {
                const oc = try self.evalExpr(pm.object, env);
                if (oc.isAbrupt()) return oc;
                return self.setPrivate(oc.normal, pm.name, value);
            },
            else => return self.throwError("ReferenceError", "invalid assignment target"),
        }
    }

    /// §14.7.5 EnumerateObjectProperties — collect the enumerable string-keyed property names of
    /// `value` and its prototype chain, each name visited once (a name shadowed lower on the chain is
    /// not revisited). M-subset: a user object's own/inherited data & accessor properties are
    /// enumerable; Array integer indices are enumerable (numeric order) but Array `length` is NOT (it
    /// is synthetic — not in the property map). A built-in prototype (`Object.prototype`,
    /// `Array.prototype`, `String.prototype`, the Error prototypes, …) holds only NON-enumerable
    /// properties per spec, but this engine stores them as plain data — so we STOP the chain walk at
    /// the first built-in prototype (everything above it is also built-in), which yields the correct
    /// observable enumeration (e.g. `for (k in [])` visits nothing, not `push`/`join`/…). Strings box
    /// to enumerable character-index keys (`length` is non-enumerable → skipped).
    fn enumerateKeys(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!void {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        switch (value) {
            .object => |start| {
                var obj: ?*Object = start;
                while (obj) |o| {
                    // Stop at a realm built-in prototype: its properties are spec-non-enumerable.
                    if (self.isBuiltinProto(o)) break;
                    // Array exotic integer indices (numeric order), then ordinary string keys. `length`
                    // is never enumerated (it is not stored in `properties`).
                    if (o.kind == .array) {
                        for (o.elements.items, 0..) |_, i| {
                            const key = try numberToString(self.arena, @floatFromInt(i));
                            if (seen.contains(key)) continue;
                            try seen.put(self.arena, key, {});
                            try out.append(self.arena, .{ .string = key });
                        }
                    }
                    var it = o.properties.iterator();
                    while (it.next()) |entry| {
                        const key = entry.key_ptr.*;
                        if (seen.contains(key)) continue;
                        try seen.put(self.arena, key, {}); // a shadowed name is skipped even if non-enumerable here
                        if (!entry.value_ptr.enumerable) continue; // §14.7.5: only enumerable own keys
                        try out.append(self.arena, .{ .string = key });
                    }
                    obj = o.prototype;
                }
            },
            .string => |s| {
                // §22.1: a primitive String boxes to character-index own properties (enumerable).
                for (0..s.len) |i| {
                    const key = try numberToString(self.arena, @floatFromInt(i));
                    try out.append(self.arena, .{ .string = key });
                }
            },
            else => {}, // §13.5 ToObject of a number/boolean → no own enumerable string keys (M-subset)
        }
    }

    /// Is `o` one of the realm's built-in prototype objects (`Object`/`Array`/`String`/Error-family
    /// `.prototype`)? Their properties are spec-non-enumerable; for-in stops the chain walk at them.
    /// Pointer-identity against the constructors seeded in `globals` (the global names map to native
    /// constructors whose `.prototype` is the prototype object). A null `globals` (unit-test direct
    /// eval) yields false — harmless, as those tests don't enumerate built-in protos.
    fn isBuiltinProto(self: *Interpreter, o: *Object) bool {
        const g = self.globals orelse return false;
        const ctors = [_][]const u8{ "Object", "Array", "String", "Function" } ++ builtins.error_names;
        for (ctors) |name| {
            const b = g.lookup(name) orelse continue;
            if (b.value != .object) continue;
            const pv = b.value.object.get("prototype") orelse continue;
            if (pv == .object and pv.object == o) return true;
        }
        return false;
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
                // §13.2.4 ArrayLiteral — `...spread` elements flatten in place; an `elision` hole
                // contributes one `undefined` element (M-subset: no true sparse model). A trailing
                // elision that the parser appended to mark `[...x,]` (a valid literal trailing comma
                // after a spread) is dropped here so it adds no element.
                var list = elems;
                if (list.len >= 2 and list[list.len - 1].* == .elision and list[list.len - 2].* == .spread) {
                    list = list[0 .. list.len - 1];
                }
                const arr = try Object.createArray(self.arena, self.arrayProto());
                const lc = try self.evalSpreadList(list, env, &arr.elements);
                if (lc.isAbrupt()) return lc;
                return .{ .normal = .{ .object = arr } };
            },
            .elision => return .{ .normal = .undefined }, // §13.2.4 array hole → `undefined` value
            .assign_pattern => |ap| {
                // §13.15.5 DestructuringAssignment — evaluate the RHS once, destructure it into the
                // refined literal pattern, and yield the RHS value.
                const rc = try self.evalExpr(ap.value, env);
                if (rc.isAbrupt()) return rc;
                const pc = try self.assignPattern(ap.target, rc.normal, env);
                if (pc.isAbrupt()) return pc;
                return .{ .normal = rc.normal };
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
                return self.getPropertyV(oc.normal, kc.normal);
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
                return self.setPropertyV(oc.normal, kc.normal, vc.normal);
            },
            .function => |f| return self.evalFunctionExpr(f, env),
            .class_expr => |c| return self.evalClass(c, env),
            .yield_expr => |y| {
                // §14.4 YieldExpression — legal only on a generator body thread (`current_gen` set).
                // A `yield` reached outside a generator at runtime should not occur (the parser rejects
                // it), but guard defensively.
                if (self.current_gen == null) return self.throwError("SyntaxError", "yield outside a generator");
                var arg: Value = .undefined;
                if (y.argument) |an| {
                    const ac = try self.evalExpr(an, env);
                    if (ac.isAbrupt()) return ac;
                    arg = ac.normal;
                }
                // §15.5.5 `yield* expr` delegates to the iterator of `expr`; plain `yield expr` performs
                // a single handoff.
                if (y.delegate) return self.doYieldDelegate(arg);
                return self.doYield(arg);
            },
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
                        const cur = try self.getPropertyV(oc.normal, kc.normal);
                        if (cur.isAbrupt()) return cur;
                        const old = toNumber(cur.normal);
                        const sc = try self.setPropertyV(oc.normal, kc.normal, .{ .number = old + delta });
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .private_member => |pm| {
                        // §13.4 `obj.#x++` — brand-checked read, ToNumber, write back.
                        const oc = try self.evalExpr(pm.object, env);
                        if (oc.isAbrupt()) return oc;
                        const cur = try self.getPrivate(oc.normal, pm.name);
                        if (cur.isAbrupt()) return cur;
                        const old = toNumber(cur.normal);
                        const sc = try self.setPrivate(oc.normal, pm.name, .{ .number = old + delta });
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
                        const s = try self.toStringCoerce(c.normal); // §13.2.8.5: ToString throws on a Symbol
                        switch (s) {
                            .abrupt => |a| return a,
                            .string => |str| try buf.appendSlice(self.arena, str),
                        }
                    }
                }
                return .{ .normal = .{ .string = buf.items } };
            },
            .this => return .{ .normal = self.this_val },
            .super_call => |args| return self.evalSuperCall(args, env),
            .super_member => |sm| {
                // §13.3.5 SuperProperty (read) — `super.x` / `super[k]`: look up on the home object's
                // [[Prototype]], with `this` = the current `this` as the receiver (for getters).
                const key = if (sm.key) |kn| blk: {
                    const kc = try self.evalExpr(kn, env);
                    if (kc.isAbrupt()) return kc;
                    break :blk try self.toString(kc.normal);
                } else sm.name;
                return self.getSuperProperty(key);
            },
            .private_member => |pm| {
                // §13.3.2 `obj.#x` — read a private member from `obj`'s private slot.
                const oc = try self.evalExpr(pm.object, env);
                if (oc.isAbrupt()) return oc;
                return self.getPrivate(oc.normal, pm.name);
            },
            .private_assign => |pa| {
                // §13.3.2 `obj.#x = v` — write a private member.
                const oc = try self.evalExpr(pa.object, env);
                if (oc.isAbrupt()) return oc;
                const vc = try self.evalExpr(pa.value, env);
                if (vc.isAbrupt()) return vc;
                return self.setPrivate(oc.normal, pa.name, vc.normal);
            },
            .private_in => |pi| {
                // §13.10.1 `#x in obj` — the ergonomic brand check. False (no throw) for a non-object
                // or an object lacking the brand; true iff `obj` carries the private name.
                const oc = try self.evalExpr(pi.object, env);
                if (oc.isAbrupt()) return oc;
                const has = oc.normal == .object and oc.normal.object.hasPrivate(pi.name);
                return .{ .normal = .{ .boolean = has } };
            },
            .spread => return self.throwError("SyntaxError", "Unexpected token '...'"), // only valid in array/call/new lists
        }
    }

    /// §15.7 PrivateGet — read PrivateName `key` from `base`'s own private slot. Accessing a private
    /// name on a non-object, or on an object lacking the brand, is a TypeError (§15.7 — the brand
    /// check). A private accessor invokes its getter with `this` = `base`; a getter-less accessor
    /// (set-only) is a TypeError on read.
    fn getPrivate(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        if (base != .object) return self.throwError("TypeError", "Cannot read private member from an object whose class did not declare it");
        const o = base.object;
        const pv = o.getPrivate(key) orelse
            return self.throwError("TypeError", "Cannot read private member from an object whose class did not declare it");
        switch (pv.payload) {
            .data => |v| return .{ .normal = v },
            .accessor => |a| {
                const getter = a.get orelse return self.throwError("TypeError", "'#x' was defined without a getter");
                return self.callFunction(getter, &.{}, base);
            },
        }
    }

    /// §15.7 PrivateSet — write PrivateName `key` on `base`'s own private slot. The brand must exist
    /// (TypeError otherwise). A private field is writable; a private method is read-only (TypeError on
    /// assignment); a private accessor invokes its setter with `this` = `base` (set-less → TypeError).
    fn setPrivate(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
        if (base != .object) return self.throwError("TypeError", "Cannot write private member to an object whose class did not declare it");
        const o = base.object;
        const pv = o.getPrivate(key) orelse
            return self.throwError("TypeError", "Cannot write private member to an object whose class did not declare it");
        switch (pv.payload) {
            .data => |v| {
                // A private METHOD slot holds a function and is not assignable; a private FIELD is.
                if (v == .object and v.object.kind == .function and v.object.call != null and v.object.call.?.is_private_method) {
                    return self.throwError("TypeError", "Cannot write to private method");
                }
                try o.setPrivate(key, value);
                return .{ .normal = value };
            },
            .accessor => |a| {
                const setter = a.set orelse return self.throwError("TypeError", "'#x' was defined without a setter");
                const sc = try self.callFunction(setter, &.{value}, base);
                if (sc.isAbrupt()) return sc;
                return .{ .normal = value };
            },
        }
    }

    /// §13.3.5 GetSuperBase + Get — resolve `super.<key>` against the active method's
    /// [[HomeObject]].[[Prototype]], invoking accessors with `this` = the current `this` (the
    /// receiver), NOT against `this`'s own properties. A missing home/proto yields `undefined`.
    fn getSuperProperty(self: *Interpreter, key: []const u8) EvalError!Completion {
        const home = self.home_object orelse return .{ .normal = .undefined };
        const base = home.prototype orelse return .{ .normal = .undefined };
        const loc = base.getProp(key) orelse return .{ .normal = .undefined };
        switch (loc.pv.payload) {
            .data => |v| return .{ .normal = v },
            // §10.2.x: a getter found on the super chain runs with `this` = the current receiver.
            .accessor => |a| {
                const getter = a.get orelse return .{ .normal = .undefined };
                return self.callFunction(getter, &.{}, self.this_val);
            },
        }
    }

    /// §13.3.7.1 SuperCall — invoke the superclass constructor with the current `this`. M-subset:
    /// the instance already exists (created proto-linked to the derived `.prototype` by `evalNew`);
    /// `super(...)` runs the parent constructor body on that same `this`, initializing parent fields
    /// and running the parent constructor logic. The superclass constructor is read from the active
    /// method's [[HomeObject]] chain (the derived constructor's home is the derived `.prototype`; its
    /// `super_ctor` carries the linked parent). Returns the (unchanged) instance value.
    fn evalSuperCall(self: *Interpreter, arg_nodes: []const *const ast.Node, env: *Environment) EvalError!Completion {
        // The active derived constructor is `home_object.constructor`; it carries the linked parent
        // (`super_ctor`) and this class's own instance fields, initialized AFTER the parent returns.
        const cur_fd = self.currentCtorData() orelse
            return self.throwError("SyntaxError", "'super' keyword unexpected here");
        var args: std.ArrayListUnmanaged(Value) = .empty;
        const alc = try self.evalSpreadList(arg_nodes, env, &args);
        if (alc.isAbrupt()) return alc;
        if (self.this_val != .object) return self.throwError("ReferenceError", "'super' called with no 'this'");
        const instance = self.this_val.object;
        // §15.7.14: run the parent constructor (its own fields-before-body for a base parent), then
        // this derived class's own instance fields — both on the existing `this`.
        if (cur_fd.super_ctor) |sup| {
            const pc = try self.runParentCtor(sup, args.items, instance);
            if (pc.isAbrupt()) return pc;
        }
        const fc = try self.initInstanceFields(cur_fd, instance);
        if (fc.isAbrupt()) return fc;
        return .{ .normal = self.this_val };
    }

    /// The active method's enclosing constructor FunctionData: the active [[HomeObject]] is the
    /// class's `.prototype`, whose `constructor` is that class's constructor (carrying `super_ctor`
    /// and the instance `fields`). Used by `super(...)` to find the parent ctor + own fields.
    fn currentCtorData(self: *Interpreter) ?@import("object.zig").FunctionData {
        const home = self.home_object orelse return null;
        const ctor_v = home.get("constructor") orelse return null;
        if (ctor_v != .object) return null;
        return ctor_v.object.call;
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
            .private_member => |pm| {
                // §13.15.2 `obj.#x ||= v` etc. — base evaluated once, brand-checked read, then the
                // guard decides whether to write the RHS to the private slot.
                const oc = try self.evalExpr(pm.object, env);
                if (oc.isAbrupt()) return oc;
                const cur = try self.getPrivate(oc.normal, pm.name);
                if (cur.isAbrupt()) return cur;
                if (!shouldAssign(la.op, cur.normal)) return cur;
                const rc = try self.evalExpr(la.value, env);
                if (rc.isAbrupt()) return rc;
                return self.setPrivate(oc.normal, pm.name, rc.normal);
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
        // §10.4.1.2 [[Construct]] of a Bound Function Exotic Object: ignore [[BoundThis]], construct the
        // (possibly nested) target with [[BoundArguments]] ++ callArgs. Collect the prepended bound args
        // by unwrapping any chain of bound functions, then `new` the underlying target.
        if (cc.normal.object.bound != null) {
            var bound_prefix: []const Value = &.{};
            var inner: *Object = cc.normal.object;
            while (inner.bound) |b| {
                bound_prefix = try self.concatArgs(b.bound_args, bound_prefix);
                inner = b.target;
            }
            var call_args: std.ArrayListUnmanaged(Value) = .empty;
            const alc = try self.evalSpreadList(n.args, env, &call_args);
            if (alc.isAbrupt()) return alc;
            const merged = try self.concatArgs(bound_prefix, call_args.items);
            return self.construct(inner, merged);
        }
        var args: std.ArrayListUnmanaged(Value) = .empty;
        const alc = try self.evalSpreadList(n.args, env, &args);
        if (alc.isAbrupt()) return alc;
        return self.construct(cc.normal.object, args.items);
    }

    /// §10.2.2 [[Construct]] — instantiate `ctor` with already-evaluated `args`. Creates the new object
    /// (proto = `ctor.prototype`), runs base/derived class field + `super` ordering, invokes the
    /// constructor body with `this` = the new object, and returns an explicit object return if any.
    /// Shared by `new C()` and a bound function's [[Construct]] (§10.4.1.2).
    fn construct(self: *Interpreter, ctor: *Object, args: []const Value) EvalError!Completion {
        // §15.3: arrow functions have no [[Construct]] — `new (() => {})` is a TypeError.
        if (ctor.call) |fd| {
            if (fd.is_arrow) return self.throwError("TypeError", "value is not a constructor");
        }
        // §20.4.1: the `Symbol` constructor has no [[Construct]] — `new Symbol()` is a TypeError.
        if (ctor.native == .symbol_ctor) return self.throwError("TypeError", "Symbol is not a constructor");
        var proto: ?*Object = null;
        if (ctor.get("prototype")) |pv| {
            if (pv == .object) proto = pv.object;
        }
        const new_obj = try Object.create(self.arena, proto);

        const is_derived = if (ctor.call) |fd| fd.is_derived_ctor else false;

        // §15.7.14 field ordering: a BASE class runs the instance FieldDefinitions on the new object
        // BEFORE the constructor body. A DERIVED class initializes its own fields AFTER `super(...)`
        // returns (done in evalSuperCall / the implicit-super path below), so they are skipped here.
        // Ordinary functions carry no fields, so this is a no-op for them.
        if (!is_derived) {
            if (ctor.call) |fd| {
                const fc = try self.initInstanceFields(fd, new_obj);
                if (fc.isAbrupt()) return fc;
            }
        }

        // §15.7.14: a DERIVED class with NO explicit constructor has a default constructor that runs
        // `super(...args)` then initializes its own fields. Synthesize that here (the body is empty).
        if (is_derived) {
            const fd = ctor.call.?;
            if (fd.body.len == 0) {
                if (fd.super_ctor) |sup| {
                    // Run the parent constructor (base or derived) on the new instance.
                    const pc = try self.runParentCtor(sup, args, new_obj);
                    if (pc.isAbrupt()) return pc;
                }
                // Then this class's own fields.
                const fc = try self.initInstanceFields(fd, new_obj);
                if (fc.isAbrupt()) return fc;
                return .{ .normal = .{ .object = new_obj } };
            }
        }

        const result = try self.callFunction(ctor, args, .{ .object = new_obj });
        if (result.isAbrupt()) return result;
        if (result.normal == .object) return .{ .normal = result.normal }; // explicit object return wins
        return .{ .normal = .{ .object = new_obj } };
    }

    /// §15.7.14: run a parent constructor `sup` on an existing `instance` (the `super(...)` /
    /// default-derived path). If the parent is itself a BASE class, its instance fields initialize
    /// before its body; a DERIVED parent runs its own body (which calls its own `super(...)`), so its
    /// fields are handled by that nested call. The parent's `home_object` is installed by callFunction.
    fn runParentCtor(self: *Interpreter, sup: *Object, args: []const Value, instance: *Object) EvalError!Completion {
        if (sup.call) |sfd| {
            if (!sfd.is_derived_ctor) {
                const fc = try self.initInstanceFields(sfd, instance);
                if (fc.isAbrupt()) return fc;
            }
        }
        return self.callFunction(sup, args, .{ .object = instance });
    }

    /// §15.7.14 InitializeInstanceElements — add this class's PrivateName brand (private fields /
    /// methods / accessors) to `instance`, then define each instance FieldDefinition on `instance`, in
    /// declaration order, evaluating its initializer with `this` = the instance, in a scope child of
    /// the class's defining environment (so an initializer may reference the class name / outer
    /// bindings). A field with no initializer is created with value `undefined`.
    fn initInstanceFields(self: *Interpreter, fd: @import("object.zig").FunctionData, instance: *Object) EvalError!Completion {
        // §15.7: install the private brand first — private methods/accessors are shared (recorded at
        // class definition), and private fields' initializers run with `this` = the instance below.
        const pc = try self.installPrivateElements(fd, instance);
        if (pc.isAbrupt()) return pc;
        if (fd.fields.len == 0) return .{ .normal = .undefined };
        const field_env = try Environment.create(self.arena, fd.closure);
        const saved_this = self.this_val;
        self.this_val = .{ .object = instance };
        defer self.this_val = saved_this;
        // §13.3.5: a field initializer's [[HomeObject]] is the class's `.prototype` (the ctor's home),
        // so `super.x` inside an initializer resolves against the superclass prototype.
        const saved_home = self.home_object;
        self.home_object = fd.home_object;
        defer self.home_object = saved_home;
        for (fd.fields) |field| {
            var v: Value = .undefined;
            if (field.init) |ie| {
                const ic = try self.evalExpr(ie, field_env);
                if (ic.isAbrupt()) return ic;
                v = ic.normal;
            }
            try instance.set(field.key, v);
        }
        return .{ .normal = .undefined };
    }

    /// §15.7 install this class's instance PrivateName elements on `instance` (its brand): private
    /// methods/accessors (shared function objects, copied/merged into the private slot) and private
    /// fields (initializer run with `this` = the instance, in the class's defining scope). Done in
    /// declaration order so a later field initializer may call an earlier private method.
    fn installPrivateElements(self: *Interpreter, fd: @import("object.zig").FunctionData, instance: *Object) EvalError!Completion {
        if (fd.private_elements.len == 0) return .{ .normal = .undefined };
        const env = try Environment.create(self.arena, fd.closure);
        const saved_this = self.this_val;
        const saved_home = self.home_object;
        self.this_val = .{ .object = instance };
        self.home_object = fd.home_object; // the class `.prototype` (so `super.x` resolves)
        defer self.this_val = saved_this;
        defer self.home_object = saved_home;
        for (fd.private_elements) |pe| {
            switch (pe.kind) {
                .method => try instance.setPrivate(pe.key, .{ .object = pe.func.? }),
                .get => try instance.definePrivateAccessor(pe.key, pe.func.?, null),
                .set => try instance.definePrivateAccessor(pe.key, null, pe.func.?),
                .field => {
                    var v: Value = .undefined;
                    if (pe.init) |ie| {
                        const ic = try self.evalExpr(ie, env);
                        if (ic.isAbrupt()) return ic;
                        v = ic.normal;
                    }
                    try instance.setPrivate(pe.key, v);
                },
            }
        }
        return .{ .normal = .undefined };
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
                    const getter: ?*Object = if (p.kind == .get) f else null;
                    const setter: ?*Object = if (p.kind == .set) f else null;
                    if (key.symbol) |sym| {
                        // §13.2.5: a symbol-keyed accessor → the symbol store (merged get+set).
                        try obj.defineSymbolAccessor(sym, getter, setter);
                    } else {
                        try obj.defineAccessor(key.key, getter, setter);
                    }
                },
                .init => {
                    const key = try self.propKey(p, env);
                    if (key.isAbrupt()) return key.completion;
                    const c = try self.evalExpr(p.value, env);
                    if (c.isAbrupt()) return c;
                    if (key.symbol) |sym| {
                        try obj.setSymbol(sym, c.normal); // §13.2.5 symbol-keyed data property
                    } else {
                        try obj.set(key.key, c.normal);
                    }
                },
            }
        }
        return .{ .normal = .{ .object = obj } };
    }

    const KeyResult = struct {
        key: []const u8 = "",
        /// Non-null when a computed `[expr]` key evaluated to a Symbol (§13.2.5 ComputedPropertyName +
        /// §7.1.19 ToPropertyKey) — the property is symbol-keyed, not string-keyed.
        symbol: ?*Symbol = null,
        completion: Completion = .{ .normal = .undefined },
        fn isAbrupt(self: KeyResult) bool {
            return self.completion.isAbrupt();
        }
    };

    /// Resolve a PropertyDefinition's key: a computed `[expr]` (evaluated → §7.1.19 ToPropertyKey: a
    /// Symbol stays a Symbol, else ToString) or the static identifier/string/numeric key parsed earlier.
    fn propKey(self: *Interpreter, p: ast.Property, env: *Environment) EvalError!KeyResult {
        if (p.computed_key) |ck| {
            const c = try self.evalExpr(ck, env);
            if (c.isAbrupt()) return .{ .completion = c };
            if (c.normal == .symbol) return .{ .symbol = c.normal.symbol };
            return .{ .key = try self.toString(c.normal) };
        }
        return .{ .key = p.key };
    }

    /// §15.7.14 resolve a ClassElement's PropertyName: a computed `[expr]` (evaluated in the class
    /// scope at definition time, ToPropertyKey → ToString in the M-subset) or the static key parsed
    /// earlier. Mirrors `propKey` for object-literal members.
    fn classElementKey(self: *Interpreter, el: ast.ClassElement, env: *Environment) EvalError!KeyResult {
        if (el.computed_key) |ck| {
            const c = try self.evalExpr(ck, env);
            if (c.isAbrupt()) return .{ .completion = c };
            return .{ .key = try self.toString(c.normal) };
        }
        return .{ .key = el.key };
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
                    if (!entry.value_ptr.enumerable) continue; // §7.3.25: own ENUMERABLE keys only
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
                const gc = try self.getPropertyV(base.value, kc.normal);
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
                if (base.value.object.call) |fd| {
                    if (fd.is_class_ctor) return .{ .completion = try self.throwError("TypeError", "Class constructor cannot be invoked without 'new'") };
                }
                const rc = try self.callFunction(base.value.object, args.items, base.this_val);
                if (rc.isAbrupt()) return .{ .completion = rc };
                return .{ .value = rc.normal };
            },
        }
    }

    /// §15.7.14 ClassDefinitionEvaluation. Builds the constructor function object: its body is the
    /// explicit `constructor` method (or a default body), its `.prototype` carries the instance
    /// methods, and the constructor object itself carries the static methods/fields. Instance
    /// FieldDefinitions are stashed on the constructor's `FunctionData.fields` and run per-instance by
    /// `evalNew`/`super(...)`. The class name is bound in an inner scope for self-reference. With an
    /// `extends` heritage (Cycle 2): the superclass is evaluated, the prototype chains are linked
    /// (`proto.[[Prototype]]` = `Super.prototype`, `ctor.[[Prototype]]` = `Super` for static
    /// inheritance; `extends null` → `proto.[[Prototype]]` = null), and every method gets a
    /// [[HomeObject]] so `super.x` resolves; a derived constructor records its `super_ctor`.
    fn evalClass(self: *Interpreter, c: *const ast.Class, env: *Environment) EvalError!Completion {
        // §15.7.14: a class is created in a new declarative scope that holds the (immutable) class
        // binding for self-reference. Methods/field initializers close over this scope.
        const class_env = try Environment.create(self.arena, env);

        // §15.7.14 ClassHeritage: evaluate `extends LHS`. `super_ctor` is the parent constructor
        // (null for `extends null` and for a non-derived class); `is_derived` is set by the presence
        // of the heritage clause (so `extends null` is still a derived class with no parent ctor).
        var super_ctor: ?*Object = null;
        var super_proto: ?*Object = null; // the prototype to link the instance `.prototype` to
        var super_proto_is_null = false; // `extends null` explicitly links to null
        const is_derived = c.superclass != null;
        if (c.superclass) |se| {
            const sc = try self.evalExpr(se, class_env);
            if (sc.isAbrupt()) return sc;
            switch (sc.normal) {
                .null => super_proto_is_null = true, // §15.7.14: `extends null`
                .object => |so| {
                    // §15.7.14: the superclass must be a constructor with an object/null `.prototype`.
                    if (so.kind != .function) return self.throwError("TypeError", "Class extends value is not a constructor or null");
                    super_ctor = so;
                    if (so.get("prototype")) |pv| {
                        if (pv == .object) super_proto = pv.object;
                    }
                },
                else => return self.throwError("TypeError", "Class extends value is not a constructor or null"),
            }
        }

        // Locate the explicit constructor (if any). Instance field records are collected during the
        // definition-order installation pass below (their keys — including computed `[expr]` keys —
        // are evaluated at class-definition time, §15.7.14 ClassElementEvaluation) and attached to the
        // constructor's FunctionData afterward.
        var ctor_fn: ?*const ast.Function = null;
        for (c.elements) |el| {
            if (el.kind == .constructor) ctor_fn = el.value.func;
        }
        var fields: std.ArrayListUnmanaged(@import("object.zig").FieldInit) = .empty;

        // §15.7.14: build the constructor function object. Default constructor: a base class gets an
        // empty body; a derived class's default constructor forwards its args to `super(...)` (handled
        // by `is_derived_ctor` + an implicit super-call in evalNew when there's no explicit ctor body).
        const ctor = try Object.createFunction(self.arena, .{
            .params = if (ctor_fn) |f| f.params else &.{},
            .rest = if (ctor_fn) |f| f.rest else null,
            .body = if (ctor_fn) |f| f.body else &.{},
            .closure = class_env,
            .is_class_ctor = true,
            .is_derived_ctor = is_derived,
            .super_ctor = super_ctor,
        });
        ctor.prototype = self.functionProto(); // §20.2.3 default; a derived class overrides to Super below
        // The constructor's `.prototype` object holds the instance methods.
        const proto: *Object = blk: {
            const pv = ctor.get("prototype") orelse break :blk try Object.create(self.arena, null);
            break :blk if (pv == .object) pv.object else try Object.create(self.arena, null);
        };
        // §15.7.14: a class constructor's [[HomeObject]] is its `.prototype` (so `super.x` in the
        // constructor resolves against `Super.prototype`); the ctor reads its own `super_ctor` for
        // `super(...)` via `proto.constructor`.
        if (ctor.call) |*fd| fd.home_object = proto;
        try proto.set("constructor", .{ .object = ctor });

        // §15.7.14 link the prototype chains for inheritance.
        if (is_derived) {
            // `proto.[[Prototype]]` = `Super.prototype` (or null for `extends null` / a parent whose
            // `.prototype` is not an object).
            proto.prototype = if (super_proto_is_null) null else super_proto;
            // `ctor.[[Prototype]]` = `Super` (static inheritance). For `extends null` there is no
            // parent constructor, so static inheritance falls back to the default function proto chain.
            ctor.prototype = super_ctor;
        }

        // §15.7.14 ClassElementEvaluation: walk the ClassBody in definition order, installing methods,
        // accessors, and static fields, and collecting instance-field records. Instance members →
        // `.prototype`, static members → the constructor object. A computed `[expr]` PropertyName is
        // evaluated HERE (definition order, ToPropertyKey → ToString in the M-subset), so its
        // side-effects interleave with the other elements. Each method/accessor's [[HomeObject]] is its
        // install target (so `super.x` inside it looks up `home_object.[[Prototype]]`).
        var private_elements: std.ArrayListUnmanaged(@import("object.zig").PrivateElement) = .empty;
        for (c.elements) |el| {
            switch (el.kind) {
                .constructor => {}, // already the [[Call]] body
                .static_block => {
                    // §15.7.11: a ClassStaticBlock runs once at class definition with `this` = the
                    // constructor, in a scope child of the class scope. Its [[HomeObject]] is the
                    // constructor (so `super.x` resolves against `Super`).
                    const block_env = try Environment.create(self.arena, class_env);
                    const saved_this = self.this_val;
                    const saved_home = self.home_object;
                    self.this_val = .{ .object = ctor };
                    self.home_object = ctor;
                    const bc = self.runBlockBody(el.value.block, block_env);
                    self.this_val = saved_this;
                    self.home_object = saved_home;
                    const r = try bc;
                    if (r.isAbrupt()) return r;
                },
                .method => {
                    const target = if (el.is_static) ctor else proto;
                    const fc = try self.evalFunctionExpr(el.value.func, class_env);
                    if (fc.isAbrupt()) return fc;
                    const f = fc.normal.object;
                    // §9.2.5: a method's [[HomeObject]] is the object it is defined on.
                    if (f.call) |*mfd| mfd.home_object = target;
                    if (el.is_private) {
                        // §15.7: a private method. Static → install on the ctor's private slot now;
                        // instance → record for per-instance install (the brand is added on each `new`).
                        if (f.call) |*mfd| mfd.is_private_method = true;
                        if (el.is_static) {
                            try ctor.setPrivate(el.key, fc.normal);
                        } else {
                            try private_elements.append(self.arena, .{ .key = el.key, .kind = .method, .func = f });
                        }
                    } else {
                        const key = try self.classElementKey(el, class_env);
                        if (key.isAbrupt()) return key.completion;
                        try target.set(key.key, fc.normal);
                    }
                },
                .get, .set => {
                    // §15.7 accessor (§13.2.5.6 model): merge a get/set pair for the same key into one
                    // accessor property on `.prototype` (instance) or the constructor (static).
                    const target = if (el.is_static) ctor else proto;
                    const fc = try self.evalFunctionExpr(el.value.func, class_env);
                    if (fc.isAbrupt()) return fc;
                    const f = fc.normal.object;
                    // §9.2.5: the accessor carries [[HomeObject]] too (so `super.x` works inside it).
                    if (f.call) |*mfd| mfd.home_object = target;
                    if (el.is_private) {
                        // §15.7: a private accessor. Static → merge into the ctor's private slot now;
                        // instance → record (merged per-instance at construction).
                        if (el.is_static) {
                            if (el.kind == .get) {
                                try ctor.definePrivateAccessor(el.key, f, null);
                            } else {
                                try ctor.definePrivateAccessor(el.key, null, f);
                            }
                        } else {
                            try private_elements.append(self.arena, .{
                                .key = el.key,
                                .kind = if (el.kind == .get) .get else .set,
                                .func = f,
                            });
                        }
                    } else {
                        const key = try self.classElementKey(el, class_env);
                        if (key.isAbrupt()) return key.completion;
                        if (el.kind == .get) {
                            try target.defineAccessor(key.key, f, null);
                        } else {
                            try target.defineAccessor(key.key, null, f);
                        }
                    }
                },
                .field => {
                    if (el.is_private) {
                        if (el.is_static) {
                            // §15.7.14: a static private field initializes at class definition with
                            // `this` = the constructor, into the ctor's private slot.
                            var v: Value = .undefined;
                            if (el.value.field_init) |ie| {
                                const saved_this = self.this_val;
                                self.this_val = .{ .object = ctor };
                                const ic = try self.evalExpr(ie, class_env);
                                self.this_val = saved_this;
                                if (ic.isAbrupt()) return ic;
                                v = ic.normal;
                            }
                            try ctor.setPrivate(el.key, v);
                        } else {
                            // §15.7.14: an instance private field — recorded; initializer runs per `new`.
                            try private_elements.append(self.arena, .{ .key = el.key, .kind = .field, .init = el.value.field_init });
                        }
                        continue;
                    }
                    const key = try self.classElementKey(el, class_env);
                    if (key.isAbrupt()) return key.completion;
                    if (el.is_static) {
                        // §15.7.14: a static field initializer runs at class definition with `this` =
                        // the constructor object.
                        var v: Value = .undefined;
                        if (el.value.field_init) |ie| {
                            const saved_this = self.this_val;
                            self.this_val = .{ .object = ctor };
                            const ic = try self.evalExpr(ie, class_env);
                            self.this_val = saved_this;
                            if (ic.isAbrupt()) return ic;
                            v = ic.normal;
                        }
                        try ctor.set(key.key, v);
                    } else {
                        // §15.7.14: the instance FieldDefinition's name is evaluated now (definition
                        // order); the initializer is run per-instance by initInstanceFields.
                        try fields.append(self.arena, .{ .key = key.key, .init = el.value.field_init });
                    }
                },
            }
        }
        // §15.7.14: stash the resolved instance-field + private-element records on the constructor.
        if (ctor.call) |*fd| {
            fd.fields = fields.items;
            fd.private_elements = private_elements.items;
        }

        // §15.7.14: bind the class name immutably in the inner scope for self-reference.
        if (c.name) |name| try class_env.declare(name, .{ .object = ctor }, false, true);

        return .{ .normal = .{ .object = ctor } };
    }

    /// Run a sequence of statements (a static block / function body) in `env`, returning the first
    /// abrupt completion (a `throw` propagates; `return`/`break`/`continue` are not produced at the
    /// top of a static block body in the M-subset). Used by §15.7.11 ClassStaticBlock evaluation.
    fn runBlockBody(self: *Interpreter, body: []const ast.Stmt, env: *Environment) EvalError!Completion {
        for (body) |stmt| {
            const cmp = try self.evalStmt(stmt, env);
            if (cmp.isAbrupt()) {
                switch (cmp) {
                    .throw => return cmp,
                    else => {}, // ret/brk/cont not meaningful at static-block top level
                }
            }
        }
        return .{ .normal = .undefined };
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
            .is_generator = f.is_generator,
            .captured_this = if (f.is_arrow) self.this_val else .undefined,
        });
        obj.prototype = self.functionProto(); // §20.2.3 so `f.call`/`.apply`/`.bind` resolve
        return .{ .normal = .{ .object = obj } };
    }

    /// Evaluate an argument / element list into `out`, flattening `...expr` spread elements
    /// (§13.2.4 / §13.3 — arrays spread their elements, strings their characters). Returns an
    /// abrupt completion to propagate, else `.{ .normal = .undefined }`.
    fn evalSpreadList(self: *Interpreter, nodes: []const *const ast.Node, env: *Environment, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
        for (nodes) |n| {
            if (n.* == .spread) {
                // §13.2.4.1 SpreadElement — iterate the source via the full §7.4 protocol (Arrays/Strings
                // fast-pathed inside `iterateToList`), appending each yielded value. Any object with a
                // `[Symbol.iterator]` spreads; a non-iterable → TypeError.
                const sc = try self.evalExpr(n.spread, env);
                if (sc.isAbrupt()) return sc;
                const ic = try self.iterateToList(sc.normal, out);
                if (ic.isAbrupt()) return ic;
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
                const got = try self.getPropertyV(oc.normal, kc.normal);
                if (got.isAbrupt()) return got;
                callee = got.normal;
            },
            .super_member => |sm| {
                // §13.3.5: `super.m(args)` — resolve `m` on the home object's [[Prototype]], but call
                // it with `this` = the CURRENT `this` (not the super base). (`super(...)` is the
                // separate SuperCall node, handled in evalExpr.)
                const key = if (sm.key) |kn| blk: {
                    const kc = try self.evalExpr(kn, env);
                    if (kc.isAbrupt()) return kc;
                    break :blk try self.toString(kc.normal);
                } else sm.name;
                const got = try self.getSuperProperty(key);
                if (got.isAbrupt()) return got;
                this_for_call = self.this_val;
                callee = got.normal;
            },
            .private_member => |pm| {
                // §13.3.2 `obj.#m(args)` — resolve the private member (brand-checked), call with
                // `this` = `obj`.
                const oc = try self.evalExpr(pm.object, env);
                if (oc.isAbrupt()) return oc;
                this_for_call = oc.normal;
                const got = try self.getPrivate(oc.normal, pm.name);
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
        // §15.7.14: a class constructor may only be invoked via `new` ([[Construct]]); a plain call
        // `C()` is a TypeError.
        if (callee.object.call) |fd| {
            if (fd.is_class_ctor) return self.throwError("TypeError", "Class constructor cannot be invoked without 'new'");
        }
        return self.callFunction(callee.object, args.items, this_for_call);
    }

    /// §10.2.1 [[Call]] — native built-in, else an ordinary AST-closure function.
    pub fn callFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        // §10.4.1.1 [[Call]] of a Bound Function Exotic Object: run the target with `this` =
        // [[BoundThis]] and args = [[BoundArguments]] ++ callArgs. Cheap early branch (the common
        // case is `.bound == null`, a single optional test off the hot path).
        if (func.bound) |b| {
            const merged = try self.concatArgs(b.bound_args, args);
            return self.callFunction(b.target, merged, b.bound_this);
        }
        if (func.native != .none) return self.callNative(func, args, this_val);
        // §15.5.4 / §27.5: calling a generator function does NOT run the body — it returns a fresh
        // Generator object in `suspended_start` (the body runs on its own thread later, on `.next`).
        // Checked before the depth bump so it pays no recursion budget; ordinary functions skip it.
        if (func.call) |fd0| {
            if (fd0.is_generator) return self.createGenerator(func, args, this_val);
        }
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
        // §10.4.4 / §15.1: an ordinary (non-arrow) function gets an `arguments` exotic binding holding
        // the call-site args (indexed data properties + a non-enumerable `length`). M-subset: an
        // ordinary object (NOT an Array exotic, so `Array.isArray(arguments)` is false) supporting
        // `arguments.length` / `arguments[i]` — what propertyHelper.js's `verifyProperty` reads. Skipped
        // when a parameter (or the rest binding) already binds the name `arguments` (it shadows). Arrows
        // inherit the enclosing `arguments` lexically, so they get none of their own.
        if (!fd.is_arrow and call_env.lookupLocal("arguments") == null) {
            const ao = try Object.create(self.arena, self.objectProto());
            for (args, 0..) |a, i| {
                const key = try numberToString(self.arena, @floatFromInt(i));
                try ao.set(key, a);
            }
            try ao.defineData("length", .{ .number = @floatFromInt(args.len) }, true, false, true);
            try call_env.declare("arguments", .{ .object = ao }, true, true);
        }
        // §15.3: an arrow has no own `this` binding — it uses the `this` captured at creation,
        // ignoring however it was called. Ordinary functions take the call-site `this`.
        const saved_this = self.this_val;
        self.this_val = if (fd.is_arrow) fd.captured_this else this_val;
        defer self.this_val = saved_this;
        // §9.2.5/§13.3.5: a method invocation installs its [[HomeObject]] for `super` resolution.
        // An arrow has no own home object — it lexically keeps the enclosing one (like `this`), so
        // it is left untouched; an ordinary function's home_object is null, masking outer `super`.
        const saved_home = self.home_object;
        if (!fd.is_arrow) self.home_object = fd.home_object;
        defer self.home_object = saved_home;

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

    /// Concatenate two argument slices into a freshly-allocated slice (`a ++ b`). Used by the bound
    /// function [[Call]]/[[Construct]] (§10.4.1) to prepend [[BoundArguments]] before the call args.
    fn concatArgs(self: *Interpreter, a: []const Value, b: []const Value) EvalError![]const Value {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const out = try self.arena.alloc(Value, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
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
                // §13.15.5.3 ArrayBindingPattern: pull values positionally from an iterable, materialized
                // via the §7.4 iterator protocol (Arrays/Strings fast-pathed; any `[Symbol.iterator]` works).
                var list: std.ArrayListUnmanaged(Value) = .empty;
                const ic = try self.iterateToList(value, &list);
                if (ic.isAbrupt()) return ic;
                const slice = list.items;
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

    /// §13.15.5.2 DestructuringAssignmentEvaluation — the assignment analogue of `bindPattern`. The
    /// `target` is a refined ArrayLiteral / ObjectLiteral (or, by recursion, a nested one). Each leaf
    /// value is PUT into an EXISTING reference (identifier env assignment with const/TDZ checks via
    /// `assignToTarget`; member `a.b` / index `a[k]`; or a further nested pattern). Defaults apply when
    /// the matched value is `undefined`. Parallels `bindPattern` but assigns instead of declaring.
    fn assignPattern(self: *Interpreter, target: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
        switch (target.*) {
            .array_literal => |elems| {
                // §13.15.5.3 ArrayAssignmentPattern — pull positionally from the iterable, materialized
                // via the §7.4 iterator protocol (Arrays/Strings fast-pathed; any `[Symbol.iterator]` works).
                var list: std.ArrayListUnmanaged(Value) = .empty;
                const ic = try self.iterateToList(value, &list);
                if (ic.isAbrupt()) return ic;
                const slice = list.items;
                for (elems, 0..) |el, i| {
                    if (el.* == .elision) continue; // hole — skip this position
                    if (el.* == .spread) {
                        // §13.15.5.3 AssignmentRestElement — leftover items become a fresh Array, then
                        // assigned to the rest target (an identifier / member / index reference).
                        const rest_arr = try Object.createArray(self.arena, self.arrayProto());
                        if (slice.len > i) for (slice[i..]) |a| try rest_arr.elements.append(self.arena, a);
                        const rc = try self.assignTargetNode(el.spread, .{ .object = rest_arr }, env);
                        if (rc.isAbrupt()) return rc;
                        break;
                    }
                    const v = if (i < slice.len) slice[i] else .undefined;
                    const tc = try self.assignElement(el, v, env);
                    if (tc.isAbrupt()) return tc;
                }
                return .{ .normal = .undefined };
            },
            .object_literal => |props| {
                // §13.15.5.4: an ObjectAssignmentPattern requires a coercible value.
                if (value == .undefined or value == .null) {
                    return self.throwError("TypeError", "Cannot destructure null or undefined");
                }
                for (props) |p| {
                    if (p.kind == .spread) {
                        // §13.15.5.4 AssignmentRestProperty — remaining own enumerable props not named
                        // by an earlier property, copied into a fresh object (CopyDataProperties).
                        const rest_obj = try Object.create(self.arena, self.objectProto());
                        if (value == .object) {
                            var it = value.object.properties.iterator();
                            while (it.next()) |entry| {
                                if (!entry.value_ptr.enumerable) continue;
                                const k = entry.key_ptr.*;
                                var taken = false;
                                for (props) |q| {
                                    if (q.kind == .init and std.mem.eql(u8, q.key, k)) {
                                        taken = true;
                                        break;
                                    }
                                }
                                if (taken) continue;
                                const gc = try self.getProperty(value, k);
                                if (gc.isAbrupt()) return gc;
                                try rest_obj.set(k, gc.normal);
                            }
                        }
                        const rc = try self.assignTargetNode(p.value, .{ .object = rest_obj }, env);
                        if (rc.isAbrupt()) return rc;
                        continue;
                    }
                    // §13.15.5.5 AssignmentProperty — `key: target = default` / shorthand `{x}` /
                    // shorthand-with-default `{x = default}`.
                    const key = try self.propKey(p, env);
                    if (key.isAbrupt()) return key.completion;
                    const gc = try self.getProperty(value, key.key);
                    if (gc.isAbrupt()) return gc;
                    var v = gc.normal;
                    // §13.2.5.1 shorthand CoverInitializedName `{x = d}`: the default lives in `p.default`
                    // (the value is the bare identifier). A `key: target = d` form folds the default into
                    // `p.value` (an `assign*` node) — `assignElement` strips and applies that one.
                    if (v == .undefined) {
                        if (p.default) |dn| {
                            const dc = try self.evalExpr(dn, env);
                            if (dc.isAbrupt()) return dc;
                            v = dc.normal;
                        }
                    }
                    const tc = try self.assignElement(p.value, v, env);
                    if (tc.isAbrupt()) return tc;
                }
                return .{ .normal = .undefined };
            },
            // A bare target reached as a pattern (shouldn't occur — callers route leaves through
            // `assignElement`/`assignTargetNode`) — assign directly.
            else => return self.assignTargetNode(target, value, env),
        }
    }

    /// One array-pattern element carrying its own `= default` tail (`[a = d]`, `[a.b = d]`, `[a[k] = d]`,
    /// `[this.#x = d]` — the literal parser folded the `=` into an `assign`/`assign_*`/`private_assign`
    /// node) or a plain target. Applies the default when `value` is `undefined`, then PUTs the value into
    /// the reference. The `assign*` shapes carry the reference inline (name / object+name / object+key),
    /// so we assign directly without reconstructing a target node.
    fn assignElement(self: *Interpreter, el: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
        switch (el.*) {
            // §13.15.5.5: `target = Initializer` — apply the default when the source value is undefined.
            .assign => |a| {
                const v = try self.applyDefault(value, a.value, env);
                if (v.isAbrupt()) return v;
                return self.assignToTarget(&.{ .identifier = a.name }, v.normal, env);
            },
            .assign_member => |m| {
                const oc = try self.evalExpr(m.object, env);
                if (oc.isAbrupt()) return oc;
                const v = try self.applyDefault(value, m.value, env);
                if (v.isAbrupt()) return v;
                return self.setProperty(oc.normal, m.name, v.normal);
            },
            .assign_index => |ix| {
                const oc = try self.evalExpr(ix.object, env);
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env);
                if (kc.isAbrupt()) return kc;
                const v = try self.applyDefault(value, ix.value, env);
                if (v.isAbrupt()) return v;
                return self.setPropertyV(oc.normal, kc.normal, v.normal);
            },
            .private_assign => |pa| {
                const oc = try self.evalExpr(pa.object, env);
                if (oc.isAbrupt()) return oc;
                const v = try self.applyDefault(value, pa.value, env);
                if (v.isAbrupt()) return v;
                return self.setPrivate(oc.normal, pa.name, v.normal);
            },
            else => return self.assignTargetNode(el, value, env), // plain / nested target, no default
        }
    }

    /// §13.15.5.5: when the destructured source `value` is `undefined`, evaluate and use `default`;
    /// otherwise keep `value`. Returns a Completion so a throwing default initializer propagates.
    fn applyDefault(self: *Interpreter, value: Value, default: *const ast.Node, env: *Environment) EvalError!Completion {
        if (value != .undefined) return .{ .normal = value };
        return self.evalExpr(default, env);
    }

    /// Assign `value` to a destructuring TARGET node: a nested array/object pattern (recurse) or a
    /// simple assignment reference (identifier / member / index — handled by `assignToTarget`).
    fn assignTargetNode(self: *Interpreter, target: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
        switch (target.*) {
            .array_literal, .object_literal => return self.assignPattern(target, value, env),
            else => return self.assignToTarget(target, value, env),
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
                switch (loc.pv.payload) {
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
            .symbol => |sym| {
                // §20.4: transparent boxing — `sym.toString`/`valueOf` resolve on Symbol.prototype, and
                // `sym.description` (§20.4.3.2) reads the [[Description]] directly.
                if (std.mem.eql(u8, key, "description")) {
                    return .{ .normal = if (sym.description) |d| .{ .string = d } else .undefined };
                }
                if (self.globalProto("Symbol")) |proto| {
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
                    if (loc.pv.payload == .accessor) {
                        const setter = loc.pv.payload.accessor.set orelse return .{ .normal = value };
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

    /// §13.3.3 / §7.1.19 ToPropertyKey-aware [[Get]] for a computed key (`a[k]`). A Symbol key routes
    /// to the symbol-keyed store (no ToString); any other key ToString's and takes the ordinary string
    /// path (the hot path, unchanged). Keeps the string get fast — the symbol branch is taken only when
    /// the key actually IS a Symbol.
    fn getPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!Completion {
        if (key == .symbol) return self.getSymbolProperty(base, key.symbol);
        return self.getProperty(base, try self.toString(key));
    }

    /// §13.3.3 ToPropertyKey-aware [[Set]] for a computed key (`a[k] = v`). Symbol → symbol store; else
    /// ToString + the ordinary string path.
    fn setPropertyV(self: *Interpreter, base: Value, key: Value, value: Value) EvalError!Completion {
        if (key == .symbol) return self.setSymbolProperty(base, key.symbol, value);
        return self.setProperty(base, try self.toString(key), value);
    }

    /// §10.1.8 [[Get]] for a Symbol key — own/inherited symbol property (data or accessor). A primitive
    /// base with no symbol slot yields undefined; null/undefined throws (matching the string path).
    fn getSymbolProperty(self: *Interpreter, base: Value, key: *Symbol) EvalError!Completion {
        switch (base) {
            .object => |o| {
                const loc = o.getSymbolProp(key) orelse return .{ .normal = .undefined };
                switch (loc.pv.payload) {
                    .data => |v| return .{ .normal = v },
                    .accessor => |a| {
                        const getter = a.get orelse return .{ .normal = .undefined };
                        return self.callFunction(getter, &.{}, base);
                    },
                }
            },
            .string => {
                // §22.1: a primitive String boxes to String.prototype for symbol keys too (so
                // `"ab"[Symbol.iterator]` resolves the iterator method).
                if (self.stringProto()) |proto| {
                    if (proto.getSymbolProp(key)) |loc| switch (loc.pv.payload) {
                        .data => |v| return .{ .normal = v },
                        .accessor => |a| {
                            const getter = a.get orelse return .{ .normal = .undefined };
                            return self.callFunction(getter, &.{}, base);
                        },
                    };
                }
                return .{ .normal = .undefined };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot read properties of null or undefined"),
            else => return .{ .normal = .undefined },
        }
    }

    /// §10.1.9 [[Set]] for a Symbol key — invoke an inherited setter if present, else define an own
    /// symbol data property. Setting on null/undefined throws; on other primitives is a no-op.
    fn setSymbolProperty(self: *Interpreter, base: Value, key: *Symbol, value: Value) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.getSymbolProp(key)) |loc| {
                    if (loc.pv.payload == .accessor) {
                        const setter = loc.pv.payload.accessor.set orelse return .{ .normal = value };
                        const sc = try self.callFunction(setter, &.{value}, base);
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = value };
                    }
                }
                try o.setSymbol(key, value);
                return .{ .normal = value };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot set properties of null or undefined"),
            else => return .{ .normal = value },
        }
    }

    // ── §7.4 Iteration protocol (Symbol.iterator) ───────────────────────────────

    /// The realm's well-known `Symbol.iterator` identity (the same value held on the `Symbol`
    /// constructor), used by GetIterator. Null only in a realm-less unit-test eval (no `Symbol`).
    fn wellKnownIterator(self: *Interpreter) ?*Symbol {
        const g = self.globals orelse return null;
        const b = g.lookup("Symbol") orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("iterator") orelse return null;
        return if (pv == .symbol) pv.symbol else null;
    }

    const IterResult = union(enum) { iterator: *Object, abrupt: Completion };

    /// §7.4.2 GetIterator ( obj ) — read `obj[Symbol.iterator]`, call it with `this` = obj, and
    /// require the result to be an object (the iterator). Returns the iterator object, or an abrupt
    /// completion (TypeError) if the value is not iterable. Null `iter_sym` (realm-less) → not iterable.
    fn getIterator(self: *Interpreter, obj: Value) EvalError!IterResult {
        const iter_sym = self.wellKnownIterator() orelse
            return .{ .abrupt = try self.throwError("TypeError", "value is not iterable") };
        const mc = try self.getSymbolProperty(obj, iter_sym);
        if (mc.isAbrupt()) return .{ .abrupt = mc };
        if (mc.normal != .object or mc.normal.object.kind != .function) {
            return .{ .abrupt = try self.throwError("TypeError", "value is not iterable") };
        }
        const rc = try self.callFunction(mc.normal.object, &.{}, obj);
        if (rc.isAbrupt()) return .{ .abrupt = rc };
        if (rc.normal != .object) {
            return .{ .abrupt = try self.throwError("TypeError", "Result of the Symbol.iterator method is not an object") };
        }
        return .{ .iterator = rc.normal.object };
    }

    const StepResult = union(enum) { value: Value, done, abrupt: Completion };

    /// §7.4.4 IteratorStep + §7.4.5 IteratorValue — call `iterator.next()`, require an object result,
    /// and return its `value` (or `.done` when `done` is truthy). An abrupt completion from `next` (or
    /// a non-object result) propagates as `.abrupt`.
    fn iteratorStep(self: *Interpreter, iterator: *Object) EvalError!StepResult {
        const nc = try self.getProperty(.{ .object = iterator }, "next");
        if (nc.isAbrupt()) return .{ .abrupt = nc };
        if (nc.normal != .object or nc.normal.object.kind != .function) {
            return .{ .abrupt = try self.throwError("TypeError", "iterator.next is not a function") };
        }
        const rc = try self.callFunction(nc.normal.object, &.{}, .{ .object = iterator });
        if (rc.isAbrupt()) return .{ .abrupt = rc };
        if (rc.normal != .object) {
            return .{ .abrupt = try self.throwError("TypeError", "Iterator result is not an object") };
        }
        const result = rc.normal.object;
        const dc = try self.getProperty(.{ .object = result }, "done");
        if (dc.isAbrupt()) return .{ .abrupt = dc };
        if (toBoolean(dc.normal)) return .done;
        const vc = try self.getProperty(.{ .object = result }, "value");
        if (vc.isAbrupt()) return .{ .abrupt = vc };
        return .{ .value = vc.normal };
    }

    /// §7.4.11 IteratorClose ( iterator, completion ) — best-effort: call `iterator.return()` if it
    /// exists, ignoring its result (the original completion is what matters). Called on an early exit
    /// from a for-of loop (`break`/`return`/`throw`). A missing/non-callable `return` is a no-op.
    fn iteratorClose(self: *Interpreter, iterator: *Object) EvalError!void {
        const rc = try self.getProperty(.{ .object = iterator }, "return");
        if (rc.isAbrupt()) return; // swallow — don't mask the original completion
        if (rc.normal != .object or rc.normal.object.kind != .function) return;
        // A throwing `return()` is swallowed (the original completion wins, §7.4.11 step 6); but an
        // engine error (OOM / step-limit) still propagates via `try`.
        _ = try self.callFunction(rc.normal.object, &.{}, .{ .object = iterator });
    }

    /// §7.4.1 GetIterator + drain — materialize an iterable `value` into a slice of its yielded values
    /// via the full Symbol.iterator protocol. Used by spread / array destructuring (which need the
    /// whole sequence up front). Arrays/Strings have native iterators (fast), but ANY object with a
    /// `[Symbol.iterator]` returning a `next`-having object works. A non-iterable → abrupt TypeError.
    fn iterateToList(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
        // Fast path: an Array iterates its `elements` directly (skips the per-element next() call),
        // preserving the hot spread/destructuring path. Strings keep their native code-unit walk.
        if (value == .object and value.object.kind == .array) {
            for (value.object.elements.items) |el| try out.append(self.arena, el);
            return .{ .normal = .undefined };
        }
        if (value == .string) {
            const s = value.string;
            for (0..s.len) |i| try out.append(self.arena, .{ .string = s[i .. i + 1] });
            return .{ .normal = .undefined };
        }
        const git = try self.getIterator(value);
        switch (git) {
            .abrupt => |c| return c,
            .iterator => |iterator| {
                while (true) {
                    const step = try self.iteratorStep(iterator);
                    switch (step) {
                        .abrupt => |c| return c,
                        .done => break,
                        .value => |v| try out.append(self.arena, v),
                    }
                }
                return .{ .normal = .undefined };
            },
        }
    }

    // ── §27.5 Generators (thread-per-generator, strict ping-pong handoff) ────────
    //
    // A tree-walker recurses on the native stack and cannot suspend mid-evaluation, so a generator
    // body runs on its OWN std.Thread, alternating strictly with the consumer: exactly ONE side runs
    // at a time (the two semaphores establish happens-before), so the body and the caller never touch
    // the shared realm arena concurrently. The dance, per `.next`/`yield`:
    //   caller:  resume_gen.post() ─────────►  body wakes from resume_gen.wait()
    //   caller:  to_caller.wait()  ◄───────── body posts to_caller at the next yield/return/throw
    // On the FIRST `.next` the body thread is spawned (it immediately runs to the first suspension and
    // posts to_caller), so the caller's first step is just `to_caller.wait()` (no resume_gen.post()).

    /// §15.5.4 / §27.5.2 generator-function [[Call]] — instead of running the body, create and return a
    /// Generator object in `suspended_start`. The args / this / home are captured now; the body binds
    /// and runs them on its own thread when first resumed (`.next`).
    fn createGenerator(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        const gen = try self.arena.create(object_mod.Generator);
        // Copy the args into the arena (the caller's `args` slice may be transient).
        const args_copy = try self.arena.dupe(Value, args);
        gen.* = .{
            .func = func,
            .args = args_copy,
            .this_val = this_val,
            .home_object = if (func.call) |fd| fd.home_object else null,
        };
        if (self.gen_registry) |reg| try reg.append(self.arena, gen);
        const obj = try Object.create(self.arena, self.generatorProto());
        obj.generator = gen;
        return .{ .normal = .{ .object = obj } };
    }

    /// §27.5.1.2/.4/.5 %GeneratorPrototype%.next/return/throw — resume the generator with the given
    /// completion kind and value, producing the next IteratorResult `{ value, done }` (or re-throwing
    /// on a throw completion that escapes the body). Runs on the CALLER thread.
    fn generatorResume(self: *Interpreter, this_val: Value, kind: object_mod.ResumeKind, value: Value) EvalError!Completion {
        if (this_val != .object or this_val.object.generator == null) {
            return self.throwError("TypeError", "Generator method called on a non-generator");
        }
        const gen = this_val.object.generator.?;

        // §27.5.3.3 step 2 / GeneratorValidate: a generator already executing cannot be re-entered.
        if (gen.state == .executing) return self.throwError("TypeError", "Generator is already running");

        // §27.5.1.2/.4/.5 on a COMPLETED generator: `.next` → {undefined, done:true}; `.return(v)` →
        // {v, done:true}; `.throw(e)` → re-throw e.
        if (gen.state == .completed) {
            return switch (kind) {
                .next => self.iterResult(.undefined, true),
                .ret => self.iterResult(value, true),
                .throw => .{ .throw = value },
            };
        }

        // §27.5.1.4/.5 on a SUSPENDED-START generator (the body never ran): `.return(v)`/`.throw(e)`
        // complete it immediately WITHOUT running the body. `.next` spawns the body thread.
        if (gen.state == .suspended_start) {
            if (kind == .ret) {
                gen.state = .completed;
                return self.iterResult(value, true);
            }
            if (kind == .throw) {
                gen.state = .completed;
                return .{ .throw = value };
            }
            // `.next` (start): spawn the body thread; it runs to the first suspension and posts.
            gen.state = .executing;
            gen.sent_value = value;
            gen.resume_kind = .next;
            const t = std.Thread.spawn(.{}, generatorBodyThread, .{ self, gen }) catch {
                gen.state = .completed;
                return self.throwError("RangeError", "Cannot spawn generator thread");
            };
            gen.thread = t;
            gen.to_caller.waitUncancelable(self.io); // wait for the first yield/return/throw
            return self.collectTransfer(gen);
        }

        // §27.5.3.3/.4 SUSPENDED-YIELD: hand the resume kind + value to the parked `yield`, run.
        gen.state = .executing;
        gen.sent_value = value;
        gen.resume_kind = kind;
        gen.resume_gen.post(self.io); // wake the parked yield
        gen.to_caller.waitUncancelable(self.io); // wait for the next yield/return/throw
        return self.collectTransfer(gen);
    }

    /// Read the gen→caller transfer slot after a handoff and turn it into the caller-side completion:
    /// a `yield` → `{ value, done:false }`; a `return` → `{ value, done:true }` (+ join the finished
    /// thread); a `throw` → re-throw in the caller (+ join). Marks `completed` on return/throw.
    fn collectTransfer(self: *Interpreter, gen: *object_mod.Generator) EvalError!Completion {
        switch (gen.transfer_kind) {
            .yield => {
                gen.state = .suspended_yield;
                return self.iterResult(gen.transfer_value, false);
            },
            .ret => {
                gen.state = .completed;
                if (gen.thread) |t| {
                    t.join();
                    gen.thread = null;
                }
                return self.iterResult(gen.transfer_value, true);
            },
            .throw => {
                gen.state = .completed;
                if (gen.thread) |t| {
                    t.join();
                    gen.thread = null;
                }
                return .{ .throw = gen.transfer_value };
            },
        }
    }

    /// The body-thread entry point (§27.5.3.3 step 4 — run the FunctionBody). Builds a fresh per-
    /// generator Interpreter that SHARES the arena + globals (safe: only one thread runs at a time)
    /// with `current_gen` set so `yield` reaches the handoff, binds params/this, runs the body, and
    /// posts the terminal completion (return/throw) to the caller. Never returns a Zig error to the
    /// thread runtime — engine errors (OOM / step-limit) are surfaced as a thrown completion.
    fn generatorBodyThread(parent: *Interpreter, gen: *object_mod.Generator) void {
        var body: Interpreter = .{
            .arena = parent.arena,
            .step_limit = parent.step_limit,
            .globals = parent.globals,
            .gen_registry = parent.gen_registry,
            .io = parent.io,
            .current_gen = gen,
        };
        const comp = body.runGeneratorBody(gen) catch |e| blk: {
            // §27.5.3.3: an engine error (step-limit / OOM) on the body thread completes the generator
            // with a thrown completion (best-effort — surface it to the caller rather than crash).
            const kind: []const u8 = if (e == error.StepLimitExceeded) "RangeError" else "Error";
            const msg: []const u8 = if (e == error.StepLimitExceeded) "step limit exceeded" else "out of memory";
            const tc = body.throwError(kind, msg) catch break :blk Completion{ .throw = .undefined };
            break :blk tc;
        };
        // Translate the body completion into the terminal transfer (return / throw).
        switch (comp) {
            .normal => |v| {
                gen.transfer_value = v;
                gen.transfer_kind = .ret;
            },
            .ret => |v| {
                gen.transfer_value = v;
                gen.transfer_kind = .ret;
            },
            .throw => |v| {
                gen.transfer_value = v;
                gen.transfer_kind = .throw;
            },
            .brk, .cont => {
                // Not producible by a well-formed body (loops consume them); treat as a plain finish.
                gen.transfer_value = .undefined;
                gen.transfer_kind = .ret;
            },
        }
        gen.to_caller.post(body.io);
    }

    /// Bind the generator's params/this/home and run its body, honoring a `.return`/`.throw` injected
    /// at the very start (`suspended_start` + abrupt resume is handled by the caller, so here the first
    /// resume is always `.next`). Mirrors the ordinary [[Call]] body setup.
    fn runGeneratorBody(self: *Interpreter, gen: *object_mod.Generator) EvalError!Completion {
        const func = gen.func;
        const fd = func.call.?;
        const args = gen.args;
        const call_env = try Environment.create(self.arena, fd.closure);
        for (fd.params, 0..) |param, i| {
            var v: Value = if (i < args.len) args[i] else .undefined;
            if (v == .undefined) {
                if (param.default) |dn| {
                    const dc = try self.evalExpr(dn, call_env);
                    if (dc.isAbrupt()) return dc;
                    v = dc.normal;
                }
            }
            if (param.pattern.* == .identifier) {
                try call_env.declare(param.pattern.identifier, v, true, true);
            } else {
                const bc = try self.bindPattern(param.pattern, v, call_env, true);
                if (bc.isAbrupt()) return bc;
            }
        }
        if (fd.rest) |rest_pat| {
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
        if (call_env.lookupLocal("arguments") == null) {
            const ao = try Object.create(self.arena, self.objectProto());
            for (args, 0..) |a, i| {
                const key = try numberToString(self.arena, @floatFromInt(i));
                try ao.set(key, a);
            }
            try ao.defineData("length", .{ .number = @floatFromInt(args.len) }, true, false, true);
            try call_env.declare("arguments", .{ .object = ao }, true, true);
        }
        self.this_val = gen.this_val;
        self.home_object = gen.home_object;
        for (fd.body) |stmt| {
            const c = try self.evalStmt(stmt, call_env);
            switch (c) {
                .normal => {},
                .ret => |v| return .{ .normal = v },
                .throw => return c,
                .brk, .cont => {},
            }
        }
        return .{ .normal = .undefined };
    }

    /// How the consumer resumed a parked `yield` — the resume kind (`.next`/`.return`/`.throw`) plus
    /// the value it carried. `abandon` is set when realm teardown woke the body to unwind it.
    const Resumption = struct { kind: object_mod.ResumeKind, value: Value, abandon: bool };

    /// §27.5.3.7 GeneratorYield core — the body-thread side of the handoff. Posts the yielded value to
    /// the caller, parks on `resume_gen`, and reports back HOW the consumer resumed (`.next`/`.return`/
    /// `.throw` + the carried value). Callers translate that into a body completion (plain `yield`) or
    /// forward it to an inner iterator (`yield*`). Only ever runs on a body thread (`current_gen` set).
    fn doYieldRaw(self: *Interpreter, value: Value) Resumption {
        const gen = self.current_gen.?;
        // Abandonment (realm teardown): once signaled, every further `yield` immediately unwinds the
        // body with a return completion (without parking), so a `yield` reached inside a `finally`
        // during the unwind cannot re-park and deadlock the joining thread.
        if (gen.abandon) return .{ .kind = .ret, .value = .undefined, .abandon = true };
        gen.transfer_value = value;
        gen.transfer_kind = .yield;
        gen.to_caller.post(self.io); // hand control to the caller
        gen.resume_gen.waitUncancelable(self.io); // park until the next .next/.return/.throw
        if (gen.abandon) return .{ .kind = .ret, .value = .undefined, .abandon = true }; // woken by cleanup
        return .{ .kind = gen.resume_kind, .value = gen.sent_value, .abandon = false };
    }

    /// §14.4.14 the `yield x` runtime — perform one handoff and translate the resumption into a body
    /// completion: a normal `.next(v)` makes the yield expression evaluate to `v`; an injected
    /// `.throw(e)` re-throws at the yield; an injected `.return(v)` returns (so the body's `finally`
    /// blocks run during unwind).
    fn doYield(self: *Interpreter, value: Value) EvalError!Completion {
        const r = self.doYieldRaw(value);
        // §27.5.3.3/.4 the resume kind decides what the yield expression "evaluates to".
        return switch (r.kind) {
            .next => .{ .normal = r.value }, // yield evaluates to the sent value
            .throw => .{ .throw = r.value }, // §27.5.3.4 inject a throw at the yield
            .ret => .{ .ret = r.value }, // §27.5.3.4 inject a return (runs finally blocks)
        };
    }

    /// §14.4.14 / §15.5.5 `yield* expr` delegation — drive the iterator of `expr`, forwarding each
    /// `.next`/`.return`/`.throw` the OUTER consumer sends to the inner iterator and re-yielding the
    /// inner's values to the outer consumer. When the inner iterator is done, the whole `yield*`
    /// expression evaluates to that final `value`. Runs on the generator body thread.
    ///   • outer `.next(v)`  → inner `next(v)`; `{done:false}` re-yields, `{done:true}` finishes yield*.
    ///   • outer `.throw(e)` → inner `throw(e)` if present (§14.4.14 step 7); else IteratorClose + a
    ///     TypeError thrown into the body (the inner has no throw handler).
    ///   • outer `.return(v)`→ inner `return(v)` if present (§14.4.14 step 8); a `{done:true}` inner
    ///     result returns that value from the body; absent `return` → return `v` directly.
    fn doYieldDelegate(self: *Interpreter, source: Value) EvalError!Completion {
        const git = try self.getIterator(source);
        const iterator: *Object = switch (git) {
            .abrupt => |c| return c,
            .iterator => |it| it,
        };
        // §14.4.14 step 5: the first inner call is `next(undefined)`; thereafter the value forwarded
        // is whatever the outer consumer sent. `received` carries the resume kind + value each round.
        var received: Resumption = .{ .kind = .next, .value = .undefined, .abandon = false };
        while (true) {
            switch (received.kind) {
                // §14.4.14 step 7.a.i: forward a normal resume to the inner iterator's `next`.
                .next => {
                    const res = try self.iteratorCall(iterator, "next", received.value, true);
                    switch (res) {
                        .abrupt => |c| return c,
                        .result => |r| {
                            if (r.done) return .{ .normal = r.value }; // §14.4.14 step 7.a.ii: yield* value
                            received = self.doYieldRaw(r.value); // re-yield; capture the next resumption
                            if (received.abandon) return .{ .ret = .undefined };
                        },
                    }
                },
                // §14.4.14 step 7.b: an outer `.throw(e)` forwards to the inner iterator's `throw`.
                .throw => {
                    const tm = try self.getProperty(.{ .object = iterator }, "throw");
                    if (tm.isAbrupt()) return tm;
                    if (tm.normal == .object and tm.normal.object.kind == .function) {
                        const rc = try self.callFunction(tm.normal.object, &.{received.value}, .{ .object = iterator });
                        if (rc.isAbrupt()) return rc;
                        const r = try self.iterResultFromValue(rc.normal);
                        switch (r) {
                            .abrupt => |c| return c,
                            .result => |ir| {
                                if (ir.done) return .{ .normal = ir.value }; // §14.4.14 step 7.b.iii
                                received = self.doYieldRaw(ir.value);
                                if (received.abandon) return .{ .ret = .undefined };
                            },
                        }
                    } else {
                        // §14.4.14 step 7.b.iii: the inner iterator has no `throw` — close it and throw a
                        // TypeError into the body (so a `try`/`catch` around the `yield*` can observe it).
                        try self.iteratorClose(iterator);
                        return self.throwError("TypeError", "The iterator does not provide a throw method");
                    }
                },
                // §14.4.14 step 8: an outer `.return(v)` forwards to the inner iterator's `return`.
                .ret => {
                    const rm = try self.getProperty(.{ .object = iterator }, "return");
                    if (rm.isAbrupt()) return rm;
                    // §14.4.14 step 8.b: a missing `return` → return the value directly (unwind the body).
                    if (rm.normal != .object or rm.normal.object.kind != .function) return .{ .ret = received.value };
                    const rc = try self.callFunction(rm.normal.object, &.{received.value}, .{ .object = iterator });
                    if (rc.isAbrupt()) return rc;
                    const r = try self.iterResultFromValue(rc.normal);
                    switch (r) {
                        .abrupt => |c| return c,
                        .result => |ir| {
                            // §14.4.14 step 8.d.iii: a done inner `return` result completes the body with
                            // that value; otherwise re-yield and keep delegating.
                            if (ir.done) return .{ .ret = ir.value };
                            received = self.doYieldRaw(ir.value);
                            if (received.abandon) return .{ .ret = .undefined };
                        },
                    }
                },
            }
        }
    }

    const IterStep = struct { value: Value, done: bool };
    const CallStepResult = union(enum) { result: IterStep, abrupt: Completion };

    /// Call `iterator[method](arg)` and decode the IteratorResult into `{ value, done }`. `pass_arg`
    /// false calls with no argument (parameterless `next()`); true forwards `arg`. A non-object result
    /// is a §7.4.4 TypeError. Used by `yield*` to drive the inner iterator's next/throw/return.
    fn iteratorCall(self: *Interpreter, iterator: *Object, method: []const u8, arg: Value, pass_arg: bool) EvalError!CallStepResult {
        const mc = try self.getProperty(.{ .object = iterator }, method);
        if (mc.isAbrupt()) return .{ .abrupt = mc };
        if (mc.normal != .object or mc.normal.object.kind != .function) {
            return .{ .abrupt = try self.throwError("TypeError", "iterator method is not a function") };
        }
        const args: []const Value = if (pass_arg) &.{arg} else &.{};
        const rc = try self.callFunction(mc.normal.object, args, .{ .object = iterator });
        if (rc.isAbrupt()) return .{ .abrupt = rc };
        return self.iterResultFromValue(rc.normal);
    }

    /// Decode an IteratorResult object into `{ value, done }` (§7.4.4 / §7.4.5). A non-object → TypeError.
    fn iterResultFromValue(self: *Interpreter, result: Value) EvalError!CallStepResult {
        if (result != .object) {
            return .{ .abrupt = try self.throwError("TypeError", "Iterator result is not an object") };
        }
        const obj = result.object;
        const dc = try self.getProperty(.{ .object = obj }, "done");
        if (dc.isAbrupt()) return .{ .abrupt = dc };
        const vc = try self.getProperty(.{ .object = obj }, "value");
        if (vc.isAbrupt()) return .{ .abrupt = vc };
        return .{ .result = .{ .value = vc.normal, .done = toBoolean(dc.normal) } };
    }

    /// Construct an IteratorResult `{ value, done }` object (§7.4.1 CreateIterResultObject), proto =
    /// %Object.prototype%. Used to package generator `.next`/`.return` results.
    fn iterResult(self: *Interpreter, value: Value, done: bool) EvalError!Completion {
        const obj = try Object.create(self.arena, self.objectProto());
        try obj.set("value", value);
        try obj.set("done", .{ .boolean = done });
        return .{ .normal = .{ .object = obj } };
    }

    /// Realm teardown: any generator left suspended (never fully consumed) has a body thread parked on
    /// `resume_gen`. Signal each to abandon and resume it so the thread unwinds and we can join it —
    /// otherwise the OS thread would linger past the realm. Best-effort (a body that ignores `abandon`
    /// would still be joined once it next yields/completes). Runs on the MAIN interpreter at end-of-run.
    pub fn cleanupGenerators(self: *Interpreter) void {
        const reg = self.gen_registry orelse return;
        for (reg.items) |gen| {
            if (gen.thread) |t| {
                if (gen.state == .suspended_yield or gen.state == .suspended_start) {
                    // Signal abandonment and wake the parked body; it unwinds (its next yield returns a
                    // return-completion that finishes the body) and posts to_caller, then we join.
                    gen.abandon = true;
                    gen.resume_kind = .ret;
                    gen.sent_value = .undefined;
                    gen.resume_gen.post(self.io);
                    gen.to_caller.waitUncancelable(self.io);
                }
                t.join();
                gen.thread = null;
                gen.state = .completed;
            }
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

    /// §13.5.1.2 / §10.1.10 [[Delete]] — remove the own property `key` from `base`. A non-configurable
    /// own property is NOT deleted and yields `false` (so `delete` on a sealed/frozen property reports
    /// correctly); an absent property yields `true`. On a primitive base, deletion is a no-op → true.
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
                if (o.properties.get(key)) |pv| {
                    if (!pv.configurable) return .{ .normal = .{ .boolean = false } }; // §10.1.10.1 step 4
                    _ = o.properties.orderedRemove(key); // ordered delete preserves the remaining keys' order
                }
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
                // §13.8.1: a Symbol operand makes ToString (string case) or ToNumber (numeric case)
                // throw a TypeError — `sym + ""` / `"" + sym` / `sym + 1` are all errors.
                if (l == .symbol or r == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a string");
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

    /// §20.2.3 %Function.prototype% — the [[Prototype]] stamped on every function object (ordinary AST
    /// closures, classes, arrows, bound) so `fn.call`/`.apply`/`.bind` resolve. Null only in a direct
    /// unit-test eval with no realm globals (those tests don't call .call/.bind).
    pub fn functionProto(self: *Interpreter) ?*Object {
        return self.globalProto("Function");
    }

    /// §20.1.3 %Object.prototype% — the default [[Prototype]] for ordinary objects (e.g. the implicit
    /// `arguments` exotic). Null only in a realm-less unit-test eval.
    pub fn objectProto(self: *Interpreter) ?*Object {
        return self.globalProto("Object");
    }

    /// §27.5 %GeneratorPrototype% — the [[Prototype]] of every Generator object (carries
    /// `next`/`return`/`throw` + `[Symbol.iterator]`). Stashed under the sentinel global name by
    /// `builtins.setup`. Null only in a realm-less unit-test eval (those don't create generators).
    fn generatorProto(self: *Interpreter) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup("%GeneratorPrototype%") orelse return null;
        return if (b.value == .object) b.value.object else null;
    }

    // ── §20.1.2 / §20.1.3 Object reflection ─────────────────────────────────

    /// §6.2.6 ToPropertyDescriptor — read a descriptor object's own `value`/`writable`/`get`/`set`/
    /// `enumerable`/`configurable` fields into a `Descriptor` (each present-or-absent via HasProperty).
    /// `get`/`set` must be callable or `undefined` (TypeError otherwise). Returns null+throw on error.
    fn toPropertyDescriptor(self: *Interpreter, attrs: Value) EvalError!union(enum) { desc: object_mod.Descriptor, abrupt: Completion } {
        if (attrs != .object) return .{ .abrupt = (try self.throwError("TypeError", "Property description must be an object")) };
        const o = attrs.object;
        var d: object_mod.Descriptor = .{};
        if (o.getProp("enumerable")) |_| {
            const c = try self.getProperty(attrs, "enumerable");
            if (c.isAbrupt()) return .{ .abrupt = c };
            d.enumerable = toBoolean(c.normal);
        }
        if (o.getProp("configurable")) |_| {
            const c = try self.getProperty(attrs, "configurable");
            if (c.isAbrupt()) return .{ .abrupt = c };
            d.configurable = toBoolean(c.normal);
        }
        if (o.getProp("value")) |_| {
            const c = try self.getProperty(attrs, "value");
            if (c.isAbrupt()) return .{ .abrupt = c };
            d.value = c.normal;
            d.has_value = true;
        }
        if (o.getProp("writable")) |_| {
            const c = try self.getProperty(attrs, "writable");
            if (c.isAbrupt()) return .{ .abrupt = c };
            d.writable = toBoolean(c.normal);
        }
        if (o.getProp("get")) |_| {
            const c = try self.getProperty(attrs, "get");
            if (c.isAbrupt()) return .{ .abrupt = c };
            if (c.normal == .undefined) {
                d.get = @as(?*Object, null);
            } else if (c.normal == .object and c.normal.object.kind == .function) {
                d.get = c.normal.object;
            } else return .{ .abrupt = (try self.throwError("TypeError", "Getter must be a function")) };
        }
        if (o.getProp("set")) |_| {
            const c = try self.getProperty(attrs, "set");
            if (c.isAbrupt()) return .{ .abrupt = c };
            if (c.normal == .undefined) {
                d.set = @as(?*Object, null);
            } else if (c.normal == .object and c.normal.object.kind == .function) {
                d.set = c.normal.object;
            } else return .{ .abrupt = (try self.throwError("TypeError", "Setter must be a function")) };
        }
        if (d.isAccessor() and d.isData()) {
            return .{ .abrupt = (try self.throwError("TypeError", "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute")) };
        }
        return .{ .desc = d };
    }

    /// §20.1.2.4 Object.defineProperty ( O, P, Attributes ).
    fn objectDefineProperty(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        if (o != .object) return self.throwError("TypeError", "Object.defineProperty called on non-object");
        const key = try self.toString(if (args.len > 1) args[1] else .undefined);
        const r = try self.toPropertyDescriptor(if (args.len > 2) args[2] else .undefined);
        switch (r) {
            .abrupt => |c| return c,
            .desc => |d| {
                const ok = try o.object.defineProperty(key, d);
                if (!ok) return self.throwError("TypeError", "Cannot redefine property");
                return .{ .normal = o };
            },
        }
    }

    /// §20.1.2.5 Object.defineProperties ( O, Properties ) — DefinePropertiesHelper over each own
    /// enumerable key of `Properties`.
    fn objectDefineProperties(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        if (o != .object) return self.throwError("TypeError", "Object.defineProperties called on non-object");
        const props = if (args.len > 1) args[1] else .undefined;
        if (props != .object) return self.throwError("TypeError", "Cannot convert undefined or null to object");
        var it = props.object.properties.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.enumerable) continue;
            const key = entry.key_ptr.*;
            const ac = try self.getProperty(props, key);
            if (ac.isAbrupt()) return ac;
            const r = try self.toPropertyDescriptor(ac.normal);
            switch (r) {
                .abrupt => |c| return c,
                .desc => |d| {
                    const ok = try o.object.defineProperty(key, d);
                    if (!ok) return self.throwError("TypeError", "Cannot redefine property");
                },
            }
        }
        return .{ .normal = o };
    }

    /// §20.1.2.8 Object.getOwnPropertyDescriptor ( O, P ) → §6.2.6 FromPropertyDescriptor or undefined.
    fn objectGetOwnPropertyDescriptor(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        if (o != .object) {
            // §20.1.2.8 step 1: ToObject — a String boxes (index/length keys); else no own props.
            if (o == .string) return self.stringDescriptor(o.string, try self.toString(if (args.len > 1) args[1] else .undefined));
            if (o == .undefined or o == .null) return self.throwError("TypeError", "Cannot convert undefined or null to object");
            return .{ .normal = .undefined };
        }
        const key = try self.toString(if (args.len > 1) args[1] else .undefined);
        // Array exotic: indices + `length` have synthetic descriptors (not in the property map).
        if (o.object.kind == .array) {
            if (std.mem.eql(u8, key, "length"))
                return self.fromDataDescriptor(.{ .number = @floatFromInt(o.object.elements.items.len) }, true, false, false);
            if (parseIndex(key)) |i| {
                if (i < o.object.elements.items.len)
                    return self.fromDataDescriptor(o.object.elements.items[i], true, true, true);
            }
        }
        const pv = o.object.properties.get(key) orelse return .{ .normal = .undefined };
        return self.fromPropertyValue(pv);
    }

    /// §6.2.6 FromPropertyDescriptor of a stored `PropertyValue` → a fresh descriptor object.
    fn fromPropertyValue(self: *Interpreter, pv: object_mod.PropertyValue) EvalError!Completion {
        const desc = try Object.create(self.arena, self.globalProto("Object"));
        switch (pv.payload) {
            .data => |v| {
                try desc.set("value", v);
                try desc.set("writable", .{ .boolean = pv.writable });
            },
            .accessor => |a| {
                try desc.set("get", if (a.get) |g| .{ .object = g } else .undefined);
                try desc.set("set", if (a.set) |s| .{ .object = s } else .undefined);
            },
        }
        try desc.set("enumerable", .{ .boolean = pv.enumerable });
        try desc.set("configurable", .{ .boolean = pv.configurable });
        return .{ .normal = .{ .object = desc } };
    }

    fn fromDataDescriptor(self: *Interpreter, value: Value, writable: bool, enumerable: bool, configurable: bool) EvalError!Completion {
        return self.fromPropertyValue(.{
            .payload = .{ .data = value },
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        });
    }

    /// A String's own index/length property descriptor (the ToObject boxing path).
    fn stringDescriptor(self: *Interpreter, s: []const u8, key: []const u8) EvalError!Completion {
        if (std.mem.eql(u8, key, "length"))
            return self.fromDataDescriptor(.{ .number = @floatFromInt(s.len) }, false, false, false);
        if (parseIndex(key)) |i| {
            if (i < s.len) return self.fromDataDescriptor(.{ .string = s[i .. i + 1] }, false, true, false);
        }
        return .{ .normal = .undefined };
    }

    /// §20.1.2.10 Object.getOwnPropertyNames ( O ) — all own string keys (enumerable or not). For an
    /// Array: the indices (numeric order) + `"length"`, then ordinary string keys.
    fn objectGetOwnPropertyNames(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        const arr = try Object.createArray(self.arena, self.arrayProto());
        switch (o) {
            .object => |obj| {
                if (obj.kind == .array) {
                    for (obj.elements.items, 0..) |_, i| {
                        try arr.elements.append(self.arena, .{ .string = try numberToString(self.arena, @floatFromInt(i)) });
                    }
                    try arr.elements.append(self.arena, .{ .string = "length" });
                }
                var it = obj.properties.iterator();
                while (it.next()) |entry| try arr.elements.append(self.arena, .{ .string = entry.key_ptr.* });
            },
            .string => |s| {
                for (0..s.len) |i| try arr.elements.append(self.arena, .{ .string = try numberToString(self.arena, @floatFromInt(i)) });
                try arr.elements.append(self.arena, .{ .string = "length" });
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
            else => {},
        }
        return .{ .normal = .{ .object = arr } };
    }

    /// §20.1.2.9 Object.getOwnPropertyDescriptors ( O ) — an object mapping each own key to its
    /// FromPropertyDescriptor result (all own string keys, enumerable or not).
    fn objectGetOwnPropertyDescriptors(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        if (o == .undefined or o == .null) return self.throwError("TypeError", "Cannot convert undefined or null to object");
        const result = try Object.create(self.arena, self.objectProto());
        if (o == .object) {
            const obj = o.object;
            if (obj.kind == .array) {
                for (obj.elements.items, 0..) |v, i| {
                    const key = try numberToString(self.arena, @floatFromInt(i));
                    const dc = try self.fromDataDescriptor(v, true, true, true);
                    try result.set(key, dc.normal);
                }
                const lc = try self.fromDataDescriptor(.{ .number = @floatFromInt(obj.elements.items.len) }, true, false, false);
                try result.set("length", lc.normal);
            }
            var it = obj.properties.iterator();
            while (it.next()) |entry| {
                const dc = try self.fromPropertyValue(entry.value_ptr.*);
                try result.set(entry.key_ptr.*, dc.normal);
            }
        }
        return .{ .normal = .{ .object = result } };
    }

    const KveKind = enum { keys, values, entries };

    /// §20.1.2.19/.23/.6 Object.keys / values / entries — over the own ENUMERABLE string keys of
    /// ToObject(O), in property order (Array indices first, then string keys; String chars for a
    /// primitive string). `keys` → the key strings; `values` → the values (getters invoked); `entries`
    /// → `[key, value]` two-element arrays.
    fn objectKeysValuesEntries(self: *Interpreter, args: []const Value, kind: KveKind) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        if (o == .undefined or o == .null) return self.throwError("TypeError", "Cannot convert undefined or null to object");
        const out = try Object.createArray(self.arena, self.arrayProto());
        var keys: std.ArrayListUnmanaged(Value) = .empty;
        try self.ownEnumerableKeys(o, &keys);
        for (keys.items) |k| {
            switch (kind) {
                .keys => try out.elements.append(self.arena, k),
                .values, .entries => {
                    const vc = try self.getProperty(o, k.string);
                    if (vc.isAbrupt()) return vc;
                    if (kind == .values) {
                        try out.elements.append(self.arena, vc.normal);
                    } else {
                        const pair = try Object.createArray(self.arena, self.arrayProto());
                        try pair.elements.append(self.arena, k);
                        try pair.elements.append(self.arena, vc.normal);
                        try out.elements.append(self.arena, .{ .object = pair });
                    }
                },
            }
        }
        return .{ .normal = .{ .object = out } };
    }

    /// §7.3.23 EnumerableOwnPropertyNames (key-collection half) — the OWN enumerable string keys of a
    /// value (no prototype walk): Array indices (numeric order), ordinary own enumerable string keys,
    /// or a primitive String's character indices. Used by Object.keys/values/entries and Object.assign.
    fn ownEnumerableKeys(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!void {
        switch (value) {
            .object => |o| {
                if (o.kind == .array) {
                    for (o.elements.items, 0..) |_, i| {
                        try out.append(self.arena, .{ .string = try numberToString(self.arena, @floatFromInt(i)) });
                    }
                }
                var it = o.properties.iterator();
                while (it.next()) |entry| {
                    if (!entry.value_ptr.enumerable) continue; // §7.3.23: enumerable own keys only
                    try out.append(self.arena, .{ .string = entry.key_ptr.* });
                }
            },
            .string => |s| {
                for (0..s.len) |i| try out.append(self.arena, .{ .string = try numberToString(self.arena, @floatFromInt(i)) });
            },
            else => {}, // number/boolean ToObject → no own enumerable string keys (M-subset)
        }
    }

    /// §20.1.2.2 Object.create ( O, Properties ) — a new ordinary object with [[Prototype]] = O (an
    /// object or null), then (if Properties is not undefined) §20.1.2.5 ObjectDefineProperties.
    fn objectCreate(self: *Interpreter, args: []const Value) EvalError!Completion {
        const proto_arg = if (args.len > 0) args[0] else .undefined;
        const proto: ?*Object = switch (proto_arg) {
            .null => null,
            .object => |p| p,
            else => return self.throwError("TypeError", "Object prototype may only be an Object or null"),
        };
        const obj = try Object.create(self.arena, proto);
        const props = if (args.len > 1) args[1] else .undefined;
        if (props != .undefined) {
            const r = try self.objectDefineProperties(&.{ .{ .object = obj }, props });
            if (r.isAbrupt()) return r;
        }
        return .{ .normal = .{ .object = obj } };
    }

    /// §20.1.2.1 Object.assign ( target, ...sources ) — ToObject(target), then for each source copy
    /// every own ENUMERABLE property (Get from source, Set on target). Returns target.
    fn objectAssign(self: *Interpreter, args: []const Value) EvalError!Completion {
        const target = if (args.len > 0) args[0] else .undefined;
        if (target == .undefined or target == .null) return self.throwError("TypeError", "Cannot convert undefined or null to object");
        if (target != .object) return .{ .normal = target }; // M-subset: primitive target wrapper is read-only → return as-is
        if (args.len > 1) for (args[1..]) |source| {
            if (source == .undefined or source == .null) continue; // §20.1.2.1 step 4.a: skip nullish
            var keys: std.ArrayListUnmanaged(Value) = .empty;
            try self.ownEnumerableKeys(source, &keys);
            for (keys.items) |k| {
                const vc = try self.getProperty(source, k.string);
                if (vc.isAbrupt()) return vc;
                const sc = try self.setProperty(target, k.string, vc.normal);
                if (sc.isAbrupt()) return sc;
            }
        };
        return .{ .normal = target };
    }

    /// §20.1.2.12 Object.getPrototypeOf ( O ) — the [[Prototype]] of ToObject(O) (an object or null).
    fn objectGetPrototypeOf(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        switch (o) {
            .object => |obj| return .{ .normal = if (obj.prototype) |p| .{ .object = p } else .null },
            .string => return .{ .normal = if (self.stringProto()) |p| .{ .object = p } else .null },
            .undefined, .null => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
            else => return .{ .normal = .null }, // number/boolean: M-subset (no boxed wrapper proto)
        }
    }

    /// §20.1.2.22 Object.setPrototypeOf ( O, proto ) — set [[Prototype]] of O to proto (object or
    /// null). A non-extensible object with a *different* current proto rejects (TypeError); a primitive
    /// O is returned unchanged. Returns O.
    fn objectSetPrototypeOf(self: *Interpreter, args: []const Value) EvalError!Completion {
        const o = if (args.len > 0) args[0] else .undefined;
        if (o == .undefined or o == .null) return self.throwError("TypeError", "Object.setPrototypeOf called on null or undefined");
        const proto_arg = if (args.len > 1) args[1] else .undefined;
        const new_proto: ?*Object = switch (proto_arg) {
            .null => null,
            .object => |p| p,
            else => return self.throwError("TypeError", "Object prototype may only be an Object or null"),
        };
        if (o != .object) return .{ .normal = o }; // primitive: no internal slot to set (M-subset)
        const obj = o.object;
        if (obj.prototype == new_proto) return .{ .normal = o }; // §10.4.7.1 step 4: same proto → ok
        if (!obj.extensible) return self.throwError("TypeError", "#<Object> is not extensible");
        obj.prototype = new_proto;
        return .{ .normal = o };
    }

    const IntegrityOp = enum { freeze, seal, prevent };

    /// §20.1.2.7/.21/.20 Object.freeze / seal / preventExtensions — apply the integrity level to O and
    /// return O. A non-object argument is returned unchanged (§20.1.2.7 step 1).
    fn objectSetIntegrity(self: *Interpreter, args: []const Value, op: IntegrityOp) EvalError!Completion {
        _ = self;
        const o = if (args.len > 0) args[0] else .undefined;
        if (o != .object) return .{ .normal = o };
        switch (op) {
            .freeze => o.object.freezeObject(),
            .seal => o.object.sealObject(),
            .prevent => o.object.extensible = false,
        }
        return .{ .normal = o };
    }

    const IntegrityTest = enum { frozen, sealed, extensible };

    /// §20.1.2.16/.17/.15 Object.isFrozen / isSealed / isExtensible. A non-object argument is treated
    /// as already frozen/sealed (true) and not extensible (false) per the spec's primitive handling.
    fn objectTestIntegrity(self: *Interpreter, args: []const Value, t: IntegrityTest) EvalError!Completion {
        _ = self;
        const o = if (args.len > 0) args[0] else .undefined;
        if (o != .object) {
            // §20.1.2.15 step 2 / §20.1.2.16-17: a primitive is non-extensible and (vacuously) frozen+sealed.
            return .{ .normal = .{ .boolean = t != .extensible } };
        }
        const r = switch (t) {
            .frozen => o.object.isFrozenObject(),
            .sealed => o.object.isSealedObject(),
            .extensible => o.object.extensible,
        };
        return .{ .normal = .{ .boolean = r } };
    }

    /// §20.1.3.2 Object.prototype.hasOwnProperty ( V ) — own property only (no chain walk).
    fn objectHasOwnProperty(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
        const key = try self.toString(if (args.len > 0) args[0] else .undefined);
        return .{ .normal = .{ .boolean = try self.hasOwnProp(this_val, key) } };
    }

    /// HasOwnProperty over the engine's value model (Array indices/length, String index/length,
    /// ordinary own property map). Used by hasOwnProperty + propertyIsEnumerable.
    fn hasOwnProp(self: *Interpreter, base: Value, key: []const u8) EvalError!bool {
        switch (base) {
            .object => |o| {
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) return true;
                    if (parseIndex(key)) |i| if (i < o.elements.items.len) return true;
                }
                return o.properties.contains(key);
            },
            .string => |s| {
                if (std.mem.eql(u8, key, "length")) return true;
                if (parseIndex(key)) |i| return i < s.len;
                return false;
            },
            .undefined, .null => {
                _ = try self.throwError("TypeError", "Cannot convert undefined or null to object");
                return false;
            },
            else => return false,
        }
    }

    /// §20.1.3.4 Object.prototype.propertyIsEnumerable ( V ).
    fn objectPropertyIsEnumerable(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
        const key = try self.toString(if (args.len > 0) args[0] else .undefined);
        const enumerable: bool = switch (this_val) {
            .object => |o| blk: {
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) break :blk false; // Array length is non-enumerable
                    if (parseIndex(key)) |i| if (i < o.elements.items.len) break :blk true;
                }
                break :blk o.isEnumerable(key);
            },
            .string => |s| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk false;
                if (parseIndex(key)) |i| break :blk i < s.len; // String chars are enumerable
                break :blk false;
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
            else => false,
        };
        return .{ .normal = .{ .boolean = enumerable } };
    }

    /// §20.1.3.3 Object.prototype.isPrototypeOf ( V ) — is `this` anywhere on V's prototype chain.
    fn objectIsPrototypeOf(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
        _ = self;
        if (this_val != .object) return .{ .normal = .{ .boolean = false } };
        const target = this_val.object;
        const v = if (args.len > 0) args[0] else .undefined;
        if (v != .object) return .{ .normal = .{ .boolean = false } };
        var p: ?*Object = v.object.prototype;
        while (p) |proto| {
            if (proto == target) return .{ .normal = .{ .boolean = true } };
            p = proto.prototype;
        }
        return .{ .normal = .{ .boolean = false } };
    }

    // ── §21.3 Math ──────────────────────────────────────────────────────────

    /// §21.3.2 Math.<name>( ...args ) — the minimal numeric subset (the harness needs `pow`; the rest
    /// are cheap companions). Each coerces its operands with ToNumber and returns a Number.
    fn mathMethod(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
        _ = self;
        const x = if (args.len > 0) toNumber(args[0]) else std.math.nan(f64);
        const y = if (args.len > 1) toNumber(args[1]) else std.math.nan(f64);
        const r: f64 = blk: {
            if (std.mem.eql(u8, name, "pow")) break :blk std.math.pow(f64, x, y); // §21.3.2.26
            if (std.mem.eql(u8, name, "floor")) break :blk @floor(x); // §21.3.2.16
            if (std.mem.eql(u8, name, "ceil")) break :blk @ceil(x); // §21.3.2.10
            if (std.mem.eql(u8, name, "round")) break :blk @floor(x + 0.5); // §21.3.2.28 (M-subset)
            if (std.mem.eql(u8, name, "trunc")) break :blk @trunc(x); // §21.3.2.38
            if (std.mem.eql(u8, name, "abs")) break :blk @abs(x); // §21.3.2.1
            if (std.mem.eql(u8, name, "sqrt")) break :blk @sqrt(x); // §21.3.2.32
            if (std.mem.eql(u8, name, "sign")) break :blk std.math.sign(x); // §21.3.2.30
            if (std.mem.eql(u8, name, "max")) { // §21.3.2.24
                var m: f64 = -std.math.inf(f64);
                for (args) |a| {
                    const v = toNumber(a);
                    if (std.math.isNan(v)) break :blk std.math.nan(f64);
                    if (v > m) m = v;
                }
                break :blk m;
            }
            if (std.mem.eql(u8, name, "min")) { // §21.3.2.25
                var m: f64 = std.math.inf(f64);
                for (args) |a| {
                    const v = toNumber(a);
                    if (std.math.isNan(v)) break :blk std.math.nan(f64);
                    if (v < m) m = v;
                }
                break :blk m;
            }
            break :blk std.math.nan(f64);
        };
        return .{ .normal = .{ .number = r } };
    }

    // ── §20.2.3 Function.prototype methods ──────────────────────────────────

    /// §20.2.3.1/.2/.3 — `Function.prototype.call`/`apply`/`bind`. `this_val` is the target function
    /// (the receiver of the method call, e.g. `f` in `f.call(...)`); step 1 of each requires it to be
    /// callable (TypeError otherwise). `name` selects the method.
    fn functionPrototypeMethod(self: *Interpreter, name: []const u8, this_val: Value, args: []const Value) EvalError!Completion {
        // §20.2.3.{1,2,3} step 1: the receiver must be callable.
        if (this_val != .object or this_val.object.kind != .function) {
            return self.throwError("TypeError", "Function.prototype method called on non-callable");
        }
        const target = this_val.object;

        if (std.mem.eql(u8, name, "call")) {
            // §20.2.3.3 Function.prototype.call ( thisArg, ...args )
            const this_arg = if (args.len > 0) args[0] else .undefined;
            const rest = if (args.len > 1) args[1..] else &.{};
            return self.callFunction(target, rest, this_arg);
        }

        if (std.mem.eql(u8, name, "apply")) {
            // §20.2.3.1 Function.prototype.apply ( thisArg, argArray )
            const this_arg = if (args.len > 0) args[0] else .undefined;
            const arg_array = if (args.len > 1) args[1] else .undefined;
            const call_args = try self.createListFromArrayLike(arg_array);
            switch (call_args) {
                .abrupt => |c| return c,
                .list => |list| return self.callFunction(target, list, this_arg),
            }
        }

        if (std.mem.eql(u8, name, "bind")) {
            // §20.2.3.2 Function.prototype.bind ( thisArg, ...args ) → §10.4.1.3 BoundFunctionCreate.
            const this_arg = if (args.len > 0) args[0] else .undefined;
            const bound_args_src = if (args.len > 1) args[1..] else &.{};
            // Copy the bound args into the realm arena (the caller's `args` slice is transient).
            const bound_args = try self.arena.dupe(Value, bound_args_src);
            const bf = try Object.createBound(self.arena, self.functionProto(), .{
                .target = target,
                .bound_this = this_arg,
                .bound_args = bound_args,
            });
            return .{ .normal = .{ .object = bf } };
        }

        return self.throwError("TypeError", "unknown Function.prototype method");
    }

    /// §7.3.18 CreateListFromArrayLike (§20.2.3.1 step 2): null/undefined → empty list; an Array →
    /// its elements; any other object → its `0..length-1` indexed values (M-subset: array-likes via
    /// `.length`); a non-object non-nullish argArray → TypeError.
    fn createListFromArrayLike(self: *Interpreter, v: Value) EvalError!union(enum) { list: []const Value, abrupt: Completion } {
        switch (v) {
            .undefined, .null => return .{ .list = &.{} },
            .object => |o| {
                if (o.kind == .array) return .{ .list = o.elements.items };
                // Generic array-like: read `length` then index 0..length-1.
                const lc = try self.getProperty(v, "length");
                if (lc.isAbrupt()) return .{ .abrupt = lc };
                const n = toNumber(lc.normal);
                const len: usize = if (n > 0 and n < 1e9) @intFromFloat(n) else 0;
                const list = try self.arena.alloc(Value, len);
                for (0..len) |i| {
                    const key = try numberToString(self.arena, @floatFromInt(i));
                    const ec = try self.getProperty(v, key);
                    if (ec.isAbrupt()) return .{ .abrupt = ec };
                    list[i] = ec.normal;
                }
                return .{ .list = list };
            },
            else => return .{ .abrupt = (try self.throwError("TypeError", "CreateListFromArrayLike called on non-object")) },
        }
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
            .math_method => return self.mathMethod(func.native_name, args),
            .array_values => return self.makeArrayIterator(this_val), // §23.1.3.34 / Array.prototype[Symbol.iterator]
            .string_iterator => return self.makeStringIterator(this_val), // §22.1.3.36 String.prototype[Symbol.iterator]
            .iterator_next => return self.iteratorNext(this_val), // §23.1.5.2.1 / §22.1.5.2.1 %…IteratorPrototype%.next
            .symbol_to_string => return self.symbolToString(this_val), // §20.4.3.3 / §20.4.3.4
            .generator_method => { // §27.5.1.2/.4/.5 %GeneratorPrototype%.next/return/throw
                const arg: Value = if (args.len > 0) args[0] else .undefined;
                const kind: object_mod.ResumeKind = if (std.mem.eql(u8, func.native_name, "return"))
                    .ret
                else if (std.mem.eql(u8, func.native_name, "throw"))
                    .throw
                else
                    .next;
                return self.generatorResume(this_val, kind, arg);
            },
            .generator_iterator => return .{ .normal = this_val }, // §27.5.1.1 returns `this`
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
                // §22.1.1.1 String ( value ) — `String(sym)` is the ALLOWED Symbol→string conversion
                // (SymbolDescriptiveString), so it routes through the infallible ToString, not the
                // throwing coercion. Other values stringify normally.
                const v: Value = if (args.len > 0) args[0] else .undefined;
                return .{ .normal = .{ .string = try self.toString(v) } };
            },
            .object_ctor => {
                if (args.len > 0 and args[0] == .object) return .{ .normal = args[0] };
                return .{ .normal = .{ .object = try Object.create(self.arena, null) } };
            },
            .object_to_string => return .{ .normal = .{ .string = "[object Object]" } },
            .function_ctor => return self.throwError("TypeError", "Function constructor is not supported"),
            .function_proto_noop => return .{ .normal = .undefined }, // §20.2.3 %Function.prototype%() → undefined
            .object_define_property => return self.objectDefineProperty(args),
            .object_define_properties => return self.objectDefineProperties(args),
            .object_get_own_property_descriptor => return self.objectGetOwnPropertyDescriptor(args),
            .object_get_own_property_descriptors => return self.objectGetOwnPropertyDescriptors(args),
            .object_get_own_property_names => return self.objectGetOwnPropertyNames(args),
            .object_keys => return self.objectKeysValuesEntries(args, .keys),
            .object_values => return self.objectKeysValuesEntries(args, .values),
            .object_entries => return self.objectKeysValuesEntries(args, .entries),
            .object_create => return self.objectCreate(args),
            .object_assign => return self.objectAssign(args),
            .object_get_prototype_of => return self.objectGetPrototypeOf(args),
            .object_set_prototype_of => return self.objectSetPrototypeOf(args),
            .object_is => return .{ .normal = .{ .boolean = ops.sameValue(if (args.len > 0) args[0] else .undefined, if (args.len > 1) args[1] else .undefined) } },
            .object_freeze => return self.objectSetIntegrity(args, .freeze),
            .object_seal => return self.objectSetIntegrity(args, .seal),
            .object_prevent_extensions => return self.objectSetIntegrity(args, .prevent),
            .object_is_frozen => return self.objectTestIntegrity(args, .frozen),
            .object_is_sealed => return self.objectTestIntegrity(args, .sealed),
            .object_is_extensible => return self.objectTestIntegrity(args, .extensible),
            .object_has_own_property => return self.objectHasOwnProperty(this_val, args),
            .object_property_is_enumerable => return self.objectPropertyIsEnumerable(this_val, args),
            .object_is_prototype_of => return self.objectIsPrototypeOf(this_val, args),
            .function_method => return self.functionPrototypeMethod(func.native_name, this_val, args),
            .symbol_ctor => return self.symbolConstructor(args), // §20.4.1.1 Symbol([description])
            .array_ctor, .array_method, .string_method, .math_method => unreachable, // handled in the first switch
            .array_values, .string_iterator, .iterator_next, .symbol_to_string => unreachable, // handled in the first switch
            .generator_method, .generator_iterator => unreachable, // handled in the first switch
            .none => unreachable,
        }
    }

    // ── §20.4 Symbol + §22.1.5/§23.1.5 native iterators ─────────────────────────

    /// §20.4.1.1 Symbol ( [ description ] ) — mint a fresh unique Symbol whose [[Description]] is
    /// ToString(description) (or undefined when omitted). Called only as a function (`new Symbol()` is
    /// rejected in `construct`).
    fn symbolConstructor(self: *Interpreter, args: []const Value) EvalError!Completion {
        const desc: ?[]const u8 = if (args.len > 0 and args[0] != .undefined)
            try self.toString(args[0]) // §20.4.1.1 step 2: ToString(description)
        else
            null;
        const sym = try builtins.newSymbol(self.arena, desc);
        return .{ .normal = .{ .symbol = sym } };
    }

    /// §20.4.3.3 Symbol.prototype.toString / §20.4.3.4 Symbol.prototype.valueOf — `this` must be a
    /// Symbol; `toString` returns its SymbolDescriptiveString, `valueOf` the Symbol itself. (The
    /// native_name selection is implicit: both share this handler, distinguished by the return.)
    fn symbolToString(self: *Interpreter, this_val: Value) EvalError!Completion {
        if (this_val != .symbol) return self.throwError("TypeError", "Symbol.prototype.toString requires that 'this' be a Symbol");
        return .{ .normal = .{ .string = try self.toString(this_val) } };
    }

    /// §23.1.5.1 CreateArrayIterator — a fresh Array Iterator object (proto = %Object.prototype% in the
    /// M-subset) carrying the array + cursor in its native `iter` slot, with a `next` method.
    fn makeArrayIterator(self: *Interpreter, this_val: Value) EvalError!Completion {
        if (this_val != .object) return self.throwError("TypeError", "Array.prototype.values requires an object");
        const iter = try Object.create(self.arena, self.objectProto());
        iter.iter = .{ .array = this_val.object, .cursor = 0 };
        try self.installIteratorNext(iter);
        return .{ .normal = .{ .object = iter } };
    }

    /// §22.1.5.1 CreateStringIterator — a fresh String Iterator object over the primitive string's
    /// code units (M-subset: byte-at-a-time, matching the engine's String indexing model).
    fn makeStringIterator(self: *Interpreter, this_val: Value) EvalError!Completion {
        const s: []const u8 = switch (this_val) {
            .string => |str| str,
            else => return self.throwError("TypeError", "String.prototype[Symbol.iterator] requires a string"),
        };
        const iter = try Object.create(self.arena, self.objectProto());
        iter.iter = .{ .string = s, .cursor = 0 };
        try self.installIteratorNext(iter);
        return .{ .normal = .{ .object = iter } };
    }

    /// Install the `next` native (non-enumerable) on a freshly created native iterator object. (The
    /// M-subset puts `next` directly on the iterator; the real %ArrayIteratorPrototype% is deferred.)
    fn installIteratorNext(self: *Interpreter, iter: *Object) EvalError!void {
        const next_fn = try Object.createNative(self.arena, .iterator_next, "next");
        next_fn.prototype = self.functionProto();
        try iter.defineData("next", .{ .object = next_fn }, true, false, true);
    }

    /// §23.1.5.2.1 / §22.1.5.2.1 %…IteratorPrototype%.next — advance the native iterator and return a
    /// fresh `{ value, done }` IteratorResult object. Reads/advances the `iter` slot; `{value:undefined,
    /// done:true}` once exhausted.
    fn iteratorNext(self: *Interpreter, this_val: Value) EvalError!Completion {
        if (this_val != .object or this_val.object.iter == null) {
            return self.throwError("TypeError", "next called on a non-iterator");
        }
        const st = &this_val.object.iter.?;
        var value: Value = .undefined;
        var done = true;
        if (st.array) |arr| {
            if (st.cursor < arr.elements.items.len) {
                value = arr.elements.items[st.cursor];
                st.cursor += 1;
                done = false;
            }
        } else if (st.string) |s| {
            if (st.cursor < s.len) {
                value = .{ .string = s[st.cursor .. st.cursor + 1] };
                st.cursor += 1;
                done = false;
            }
        }
        const result = try Object.create(self.arena, self.objectProto());
        try result.set("value", value);
        try result.set("done", .{ .boolean = done });
        return .{ .normal = .{ .object = result } };
    }

    /// §7.1.17 ToString — delegates to the abstract operation (handles Array join). Used for property
    /// keys and engine-internal stringification, where a Symbol never reaches it (computed keys route
    /// to the symbol store first). The user-facing string COERCION contexts (template / `+`) use
    /// `toStringCoerce`, which throws on a Symbol per spec.
    pub fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
        return ops.toString(self.arena, v);
    }

    const CoerceResult = union(enum) { string: []const u8, abrupt: Completion };

    /// §7.1.17 ToString in a coercion context (template substitution, string `+`): a Symbol is a
    /// TypeError (§7.1.17 step 3) — it must NOT be silently stringified. All other types delegate to
    /// the ordinary ToString.
    fn toStringCoerce(self: *Interpreter, v: Value) EvalError!CoerceResult {
        if (v == .symbol) return .{ .abrupt = try self.throwError("TypeError", "Cannot convert a Symbol value to a string") };
        return .{ .string = try self.toString(v) };
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
