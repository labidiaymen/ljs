//! Extracted from interpreter.zig (behavior-preserving split). Free functions taking
//! `self: *Interpreter`; thin wrappers remain on the struct for cross-module/native call sites.
const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const sutf16 = @import("string_utf16.zig");
const builtins = @import("builtins.zig");
const builtin_proxy = @import("builtin_proxy.zig");
const ProxyData = @import("runtime_types.zig").ProxyData;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_expr = @import("interp_expr.zig");
const interp_destr = @import("interp_destr.zig");
const interp_ops = @import("interp_ops.zig");
const interp_async = @import("interp_async.zig");

const toBoolean = ops.toBoolean;
const strictEquals = ops.strictEquals;
const numberToString = ops.numberToString;

// Shared free helpers + named types (defined in interpreter.zig), aliased for natural call sites.
const blockNeedsScope = interpreter.blockNeedsScope;
const blockHasUsing = interpreter.blockHasUsing;
const loopHandles = Interpreter.loopHandles;
const IdRef = Interpreter.IdRef;
const HeadBinding = Interpreter.HeadBinding;
const IterStep = Interpreter.IterStep;

const paramCount = interp_expr.paramCount;
const setConstructorBackref = interp_expr.setConstructorBackref;
const setFunctionLength = interp_expr.setFunctionLength;

/// Snapshot the labels applying to the iteration/switch statement now being evaluated and clear
/// `pending_labels` (so the statement's own body inherits no labels). Hot-loop fast path: an
/// unlabeled loop sees an empty set and returns an empty slice with no allocation. A labelled loop
/// dupes the names into the arena (the live buffer may be mutated by nested labelled statements).
pub fn takeLabels(self: *Interpreter) []const []const u8 {
    const n = self.pending_labels.items.len;
    if (n == 0) return &.{};
    const out = self.arena.dupe([]const u8, self.pending_labels.items) catch &.{};
    self.pending_labels.clearRetainingCapacity();
    return out;
}

pub fn evalStmt(self: *Interpreter, stmt: ast.Stmt, env: *Environment) EvalError!Completion {
    try self.tick();
    // §14.13: the label(s) applying to THIS statement (set by an enclosing `labeled_stmt`) belong
    // to this statement alone — capture them and clear `pending_labels` so they don't leak into any
    // nested statement (e.g. `L: { for(;;)… }` — `L` labels the block, NOT the inner loop). Only an
    // iteration/switch statement uses `my_labels`; the hot path (no label) takes an empty slice.
    const my_labels = takeLabels(self);
    switch (stmt) {
        .expr => |e| return self.evalExpr(e, env),
        .declaration => |d| {
            // §14.3 declarations. Deliberate, documented M1 cuts (no hoisting pass yet):
            //   (a) `var` is block-scoped here, NOT function/global-hoisted (§14.3.2/§10.2.11);
            //   (b) the let/const temporal dead zone is not enforced — bindings are created
            //       initialized, so the `!initialized` check below is staged, not yet live.
            // (M33: duplicate lexical declarations ARE now a parse-phase SyntaxError —
            //  §14.2.1/§14.12.1/§14.15.1/§16.1.1, enforced by the static pass in parser.zig.)
            // Tightened in later M1 cycles. None of these affect the US1 acceptance scenarios.
            // §14.3.1 `using`/`await using` are immutable (const-like) block-scoped bindings that
            // additionally register a DisposableResource on the enclosing scope's dispose stack.
            const is_using = d.kind == .using_decl or d.kind == .await_using_decl;
            const mutable = d.kind != .const_decl and !is_using;
            for (d.decls) |dec| {
                var v: Value = .undefined;
                if (dec.init) |ie| {
                    const c = try self.evalExpr(ie, env);
                    if (c.isAbrupt()) return c;
                    v = c.normal;
                    // §8.4 NamedEvaluation: `let f = function(){}` / `() => {}` / `class {}` — an
                    // anonymous function/class initializer of a single-identifier binding gets the
                    // binding name. (Pattern targets are not naming contexts.)
                    if (dec.target.* == .identifier) try self.maybeSetAnonName(ie, v, dec.target.identifier);
                }
                // §ER AddDisposableResource: for `using`/`await using`, resolve + validate the
                // dispose method and push the resource (before binding — a non-callable
                // `[@@dispose]` is a TypeError that aborts the declaration).
                if (is_using) {
                    const pc = try interp_ops.disposePush(self, v, d.kind == .await_using_decl);
                    if (pc.isAbrupt()) return pc;
                }
                // §10.2.11: a `var` binds into the nearest VariableEnvironment (where `hoistVarNames`
                // instantiated it); let/const/using bind in the current scope. When lexically inside a
                // `with`, a `var x = e` initializer is the AssignmentExpression `x = e` evaluated in the
                // running context (§14.3.2.3 step 4) — its PutValue must consult the with object's
                // object Environment Record (so it writes to a shadowing property of the binding object),
                // NOT a fresh binding in the throwaway with-env. The `var` name itself was already
                // hoisted into the real VariableEnvironment by `hoistVarNames`.
                const is_var = d.kind == .var_decl;
                if (is_var and dec.target.* == .identifier and dec.init != null and
                    self.with_depth > 0 and varInWithReach(env))
                {
                    // §14.3.2.3 / §13.3.1.1: when lexically inside a `with`, `var x = e` is the
                    // AssignmentExpression `x = e` — its PutValue(ResolveBinding("x"), v) must consult
                    // the with object's object Environment Record (writing to a shadowing property of the
                    // binding object), then fall through to the hoisted binding in the VariableEnvironment.
                    // (A bare `var x;` stays a no-op; pattern targets keep the var-target binding path —
                    // a `var`-pattern inside a `with` is vanishingly rare in practice.)
                    const ac = try putWithAwareIdentifier(self, dec.target.identifier, v, env);
                    if (ac.isAbrupt()) return ac;
                    continue;
                }
                const target_env = if (is_var) varInitTarget(env) else env;
                if (dec.target.* == .identifier) {
                    if (is_var) {
                        // §14.3.2.1: a bare `var x;` is a no-op (the hoisted binding keeps its value —
                        // e.g. a same-named parameter); `var x = e` (re)declares a mutable binding.
                        if (dec.init != null) try target_env.declare(dec.target.identifier, v, true, true);
                    } else {
                        try env.declare(dec.target.identifier, v, mutable, true);
                    }
                } else {
                    // A `var` BindingPattern always has an initializer (parser-enforced); bind its
                    // names into the var target (let/const patterns bind in the current scope).
                    const bc = try interp_destr.bindPattern(self, dec.target, v, target_env, mutable);
                    if (bc.isAbrupt()) return bc;
                }
            }
            return .{ .normal = .undefined };
        },
        .block => |stmts| {
            // §14.2 Block. Allocate a child scope only when the block actually has lexical
            // declarations (let/const/using/function); declaration-free blocks (e.g. hot loop
            // bodies) reuse the parent env — avoids a per-iteration allocation.
            // §ER: a block lexically containing a `using` runs DisposeResources at exit (normal OR
            // abrupt) — handled by `runScope`. Gated so an ordinary block never touches the path.
            if (blockNeedsScope(stmts)) return runScope(self, stmts, try Environment.create(self.arena, env));
            return runBlock(self, stmts, env);
        },
        .func_decl => |f| {
            // §15.2 — bind a function object to its name in the current scope. At a Script / function
            // body / block scope entry, `hoistFunctionDeclarations` already created the binding
            // (initialized to a closure) so a forward reference (`f(); function f(){}`) resolves.
            // Re-running here refreshes the binding to a closure captured over the CURRENT env — this
            // matters for a declaration inside a block / loop body that is re-entered with a fresh
            // scope per iteration (each closure must see that iteration's bindings).
            const obj = try instantiateFunctionObject(self, f, env);
            if (f.name) |name| try env.declare(name, .{ .object = obj }, true, true);
            return .{ .normal = .undefined };
        },
        .class_decl => |c| {
            // §15.7.14 ClassDefinitionEvaluation — build the constructor, then bind the class
            // name in the current (declaration) scope.
            const cc = try interp_expr.evalClass(self, c, env);
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
                    .normal => {},
                    .cont => |l| if (!loopHandles(l, my_labels)) return bc, // labelled `continue` for an outer loop
                    .brk => |l| if (loopHandles(l, my_labels)) break else return bc,
                    .ret, .throw => return bc,
                }
            }
            return .{ .normal = .undefined };
        },
        .do_while_stmt => |s| {
            // §14.7.2 DoWhileStatement — body runs first, then the condition gates repetition.
            while (true) {
                const bc = try self.evalStmt(s.body.*, env);
                switch (bc) {
                    .normal => {},
                    .cont => |l| if (!loopHandles(l, my_labels)) return bc,
                    .brk => |l| if (loopHandles(l, my_labels)) break else return bc,
                    .ret, .throw => return bc,
                }
                const cc = try self.evalExpr(s.cond, env);
                if (cc.isAbrupt()) return cc;
                if (!toBoolean(cc.normal)) break;
            }
            return .{ .normal = .undefined };
        },
        .for_stmt => |s| {
            // §14.7.4 ForStatement: only a LEXICAL head (`let`/`const`/`using`) needs a fresh
            // per-iteration scope (CreatePerIterationEnvironment). A `var` head hoists out to the
            // VariableEnvironment, and an expression/empty head declares nothing — so those run
            // directly in `env`, avoiding an empty per-iteration scope and a wasted resolution hop.
            const head_is_lexical = if (s.init) |i| i.* == .declaration and switch (i.*.declaration.kind) {
                .let_decl, .const_decl, .using_decl, .await_using_decl => true,
                else => false,
            } else false;
            const loop_env = if (head_is_lexical) try Environment.create(self.arena, env) else env;
            // §ER: `for (using x = … ; … ; … )` — the using resource(s) are created once in the
            // head and disposed when the WHOLE loop completes (normal OR abrupt). Gated: only a
            // using-headed for-loop touches the dispose stack.
            const for_uses = if (s.init) |i| i.* == .declaration and
                (i.*.declaration.kind == .using_decl or i.*.declaration.kind == .await_using_decl) else false;
            if (for_uses) {
                const marker = self.disposables.items.len;
                const lc = try runForBody(self, s, loop_env, my_labels);
                return self.disposeFrom(marker, lc);
            }
            return runForBody(self, s, loop_env, my_labels);
        },
        .for_in_stmt => |s| return evalForIn(self, s, env, my_labels),
        .for_of_stmt => |s| return if (s.is_await) evalForAwaitOf(self, s, env, my_labels) else evalForOf(self, s, env, my_labels),
        .throw_stmt => |e| {
            // §14.14 ThrowStatement.
            const c = try self.evalExpr(e, env);
            if (c.isAbrupt()) return c;
            return .{ .throw = c.normal };
        },
        .try_stmt => |s| {
            // §14.15 TryStatement — catch handles a throw; finally's abrupt completion wins. Each
            // of the try / catch / finally bodies is its own lexical scope; `runScope` applies the
            // §ER dispose epilogue when that body directly contains a `using`/`await using`.
            var result = try runScope(self, s.block, try Environment.create(self.arena, env));
            if (result == .throw and s.catch_block != null) {
                const catch_env = try Environment.create(self.arena, env);
                // §14.15.2 CatchClauseEvaluation: BindingInitialization of the CatchParameter
                // (BindingIdentifier or destructuring BindingPattern) with the thrown value. A throw
                // raised by the binding (e.g. a non-iterable for `catch([a])`) replaces the original
                // and skips the Catch Block — but `finally` below still runs.
                var bound = true;
                if (s.catch_param) |pat| {
                    const bc = try interp_destr.bindPattern(self, pat, result.throw, catch_env, true);
                    if (bc.isAbrupt()) {
                        result = bc;
                        bound = false;
                    }
                }
                if (bound) result = try runScope(self, s.catch_block.?, catch_env);
            }
            if (s.finally_block) |fb| {
                const fc = try runScope(self, fb, try Environment.create(self.arena, env));
                if (fc.isAbrupt()) return fc;
            }
            return result;
        },
        .break_stmt => |label| return .{ .brk = label },
        .continue_stmt => |label| return .{ .cont = label },
        .labeled_stmt => |s| {
            // §14.13 LabelledStatement. The labels applying to THIS statement (`my_labels`, captured
            // and cleared at the top) plus this label are republished as `pending_labels` for the
            // immediately-nested statement: an iteration/switch statement snapshots the whole set (so
            // `continue label`/`break label` and a chain `a: b: for…` target it); a non-iteration
            // labelled statement (e.g. a block) absorbs a matching `break label` here.
            self.pending_labels.clearRetainingCapacity();
            for (my_labels) |l| try self.pending_labels.append(self.arena, l);
            try self.pending_labels.append(self.arena, s.label);
            const bc = try self.evalStmt(s.body.*, env);
            self.pending_labels.clearRetainingCapacity(); // consumed (or unused by a non-loop body)
            switch (bc) {
                .brk => |l| if (l != null and std.mem.eql(u8, l.?, s.label)) return .{ .normal = .undefined },
                else => {},
            }
            return bc;
        },
        .switch_stmt => |s| {
            // §14.12 SwitchStatement — match by ===, fall through, `break` exits. A switch is a
            // `break` target (label-less, or labelled when wrapped in `L:`), never a `continue` one.
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
                    const bc = try runBlock(self, case.body, sw_env);
                    switch (bc) {
                        .normal => {},
                        .brk => |l| if (loopHandles(l, my_labels)) return .{ .normal = .undefined } else return bc,
                        .ret, .throw, .cont => return bc,
                    }
                }
                if (matched) break;
            }
            return .{ .normal = .undefined };
        },
        .with_stmt => |s| {
            // §14.11.7 — ToObject the operand, run the body in an object Environment Record whose
            // binding object is it. null/undefined → TypeError (§7.1.18). `with_depth` gates
            // identifier resolution onto the object while the `with` body executes.
            const oc = try self.evalExpr(s.object, env);
            if (oc.isAbrupt()) return oc;
            const obj: *Object = switch (oc.normal) {
                .object => |o| o,
                .null, .undefined => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
                else => try Object.create(self.arena, self.objectProto()), // M-subset: primitive ToObject boxing not modeled
            };
            const with_env = try Environment.create(self.arena, env);
            with_env.with_object = obj;
            self.with_depth += 1;
            defer self.with_depth -= 1;
            return self.evalStmt(s.body.*, with_env);
        },
    }
}

pub fn resolveIdRef(self: *Interpreter, env: *Environment, name: []const u8) IdRef {
    _ = self;
    var e: ?*Environment = env;
    while (e) |cur| {
        if (cur.with_object) |opaque_obj| {
            const obj: *Object = @ptrCast(@alignCast(opaque_obj));
            if (obj.get(name) != null) return .{ .with_object = obj }; // §9.1.1.2.1 HasProperty (proto chain)
        } else if (cur.vars.getPtr(name)) |b| {
            return .{ .binding = b };
        }
        e = cur.parent;
    }
    return .unresolved;
}

/// §8.2.6 / §14.2.3 / §10.2.11 lexical pre-declaration (the §10/§14 *DeclarationInstantiation*
/// step for lexical names): create each top-level `let`/`const`/`class` BoundName of `stmts` in
/// `env` as an UNINITIALIZED binding (its Temporal Dead Zone). When the declaration statement later
/// runs it initializes the binding (`declare` with `initialized = true`). This makes a *reference*
/// to a lexical name BEFORE its declaration line a §13.x TDZ ReferenceError (read AND PutValue),
/// rather than resolving to an outer scope or — for an assignment — wrongly creating a global. Only
/// the scope's OWN top-level declarations are hoisted (nested blocks/loops/functions have their own
/// scope + pass); `var`/`function` are not lexical (function declarations are separately created
/// initialized). Names already present in `env` (the rare re-entry) are left untouched.
pub fn hoistLexicalNames(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!void {
    for (stmts) |s| switch (s) {
        .declaration => |d| {
            if (d.kind == .var_decl) continue; // §13.3.2 `var` is not a lexical (no TDZ here)
            for (d.decls) |dec| try hoistPatternNames(self, dec.target, env);
        },
        .class_decl => |c| {
            // §15.7: a ClassDeclaration introduces a lexical (let-like) binding for its name.
            if (c.name) |nm| if (env.lookupLocal(nm) == null)
                try env.declare(nm, .undefined, true, false); // uninitialized → TDZ
        },
        else => {},
    };
}

/// §10.2.5 OrdinaryFunctionCreate + §10.2.4 MakeConstructor for a FunctionDeclaration: build the
/// closure object capturing `env`, install `length`/`name`/`prototype`. Shared by the §15.2
/// declaration-statement arm and `hoistFunctionDeclarations` so a hoisted function and the value
/// re-bound when its declaration line runs are built identically.
pub fn instantiateFunctionObject(self: *Interpreter, f: *const ast.Function, env: *Environment) EvalError!*Object {
    const obj = try Object.createFunction(self.arena, .{ .params = f.params, .rest = f.rest, .body = f.body, .closure = env, .is_generator = f.is_generator, .is_async = f.is_async, .strict = f.strict });
    obj.prototype = self.functionProto(); // §20.2.3 so `f.call`/`.apply`/`.bind` resolve
    // §20.2.4.1/.2: a declaration always has a name; install `length` + `name`.
    try setFunctionLength(obj, paramCount(f.params));
    try self.setFunctionName(obj, f.name orelse "", "");
    try setConstructorBackref(obj); // §10.2.4 MakeConstructor: F.prototype.constructor === F
    try interp_expr.finalizeFunctionPrototype(self, obj); // §10.2.4/§27.5.1 prototype descriptor + proto link
    return obj;
}

/// §10.2.11 / §16.1.7 / §14.2.3 FunctionDeclarationInstantiation (function step): for each
/// top-level `FunctionDeclaration` of `stmts` (the scope's OWN immediate statements only — NOT
/// descending into nested blocks/loops/functions), create the closure ONCE and bind its name as an
/// INITIALIZED binding in `env` BEFORE any statement runs. This is what makes a forward reference
/// (`f(); function f(){}`) and `typeof f === "function"` before the declaration line work.
///
/// A later duplicate top-level declaration of the same name wins (last one is instantiated last),
/// matching §10.2.11 step 28 (instantiated functions in source order, each overwriting the prior).
/// Run AFTER `hoistLexicalNames`/`hoistVarNames` at each scope-entry site so the initialized
/// function binding clobbers any `var`-hoisted `undefined` of the same name (§B.3.3 / step ordering)
/// and is itself a plain mutable binding (functions are not lexical / no TDZ).
pub fn hoistFunctionDeclarations(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!void {
    for (stmts) |s| switch (s) {
        .func_decl => |f| {
            const name = f.name orelse continue;
            const obj = try instantiateFunctionObject(self, f, env);
            try env.declare(name, .{ .object = obj }, true, true);
        },
        else => {},
    };
}

/// Pre-declare every BindingIdentifier in a lexical-declaration pattern as uninitialized (TDZ).
pub fn hoistPatternNames(self: *Interpreter, pattern: *const ast.Pattern, env: *Environment) EvalError!void {
    switch (pattern.*) {
        .identifier => |n| {
            if (env.lookupLocal(n) == null) try env.declare(n, .undefined, true, false);
        },
        .array => |ap| {
            for (ap.elements) |el| if (el.target) |t| try hoistPatternNames(self, t, env);
            if (ap.rest) |r| try hoistPatternNames(self, r, env);
        },
        .object => |op| {
            for (op.properties) |prop| try hoistPatternNames(self, prop.target, env);
            if (op.rest) |r| if (env.lookupLocal(r) == null) try env.declare(r, .undefined, true, false);
        },
    }
}

/// §10.2.11 / §16.1.7 VarDeclaredNames instantiation: walk `stmts`, descending into nested
/// non-function statements (blocks, if/while/do/for/for-in/for-of/try/with/switch/labeled bodies)
/// but STOPPING at function/class boundaries, and create each `var` BoundName as an INITIALIZED
/// `undefined` binding in `scope` — UNLESS already present (so a parameter, an earlier `var`, or a
/// hoisted function of the same name is not clobbered). Mirrors the parser's `collectVarNames`.
/// FunctionDeclarations are NOT collected (§14.2.2) — they are instantiated separately. Run once
/// per Function/Script/eval entry, after `hoistLexicalNames`.
pub fn hoistVarNames(self: *Interpreter, stmts: []const ast.Stmt, scope: *Environment) EvalError!void {
    for (stmts) |s| try hoistVarNamesStmt(self, s, scope);
}

pub fn hoistVarNamesStmt(self: *Interpreter, stmt: ast.Stmt, scope: *Environment) EvalError!void {
    switch (stmt) {
        .declaration => |d| {
            if (d.kind == .var_decl) for (d.decls) |dec| try hoistVarPattern(self, dec.target, scope);
        },
        .block => |stmts| try self.hoistVarNames(stmts, scope),
        .if_stmt => |s| {
            try hoistVarNamesStmt(self, s.then.*, scope);
            if (s.otherwise) |e| try hoistVarNamesStmt(self, e.*, scope);
        },
        .while_stmt => |s| try hoistVarNamesStmt(self, s.body.*, scope),
        .do_while_stmt => |s| try hoistVarNamesStmt(self, s.body.*, scope),
        .for_stmt => |s| {
            if (s.init) |i| if (i.* == .declaration and i.declaration.kind == .var_decl)
                for (i.declaration.decls) |dec| try hoistVarPattern(self, dec.target, scope);
            try hoistVarNamesStmt(self, s.body.*, scope);
        },
        .for_in_stmt => |s| {
            if (s.head == .decl and s.head.decl.kind == .var_decl) try hoistVarPattern(self, s.head.decl.target, scope);
            try hoistVarNamesStmt(self, s.body.*, scope);
        },
        .for_of_stmt => |s| {
            if (s.head == .decl and s.head.decl.kind == .var_decl) try hoistVarPattern(self, s.head.decl.target, scope);
            try hoistVarNamesStmt(self, s.body.*, scope);
        },
        .try_stmt => |s| {
            try self.hoistVarNames(s.block, scope);
            if (s.catch_block) |cb| try self.hoistVarNames(cb, scope);
            if (s.finally_block) |fb| try self.hoistVarNames(fb, scope);
        },
        .with_stmt => |s| try hoistVarNamesStmt(self, s.body.*, scope),
        .switch_stmt => |s| for (s.cases) |cs| try self.hoistVarNames(cs.body, scope),
        .labeled_stmt => |s| try hoistVarNamesStmt(self, s.body.*, scope),
        else => {},
    }
}

/// Declare each BindingIdentifier of a `var` pattern as an initialized `undefined` binding in
/// `scope`, skipping names already bound (no-clobber). Unlike `hoistPatternNames` (lexical TDZ),
/// `var` bindings are created already-initialized (§10.2.11).
pub fn hoistVarPattern(self: *Interpreter, pattern: *const ast.Pattern, scope: *Environment) EvalError!void {
    switch (pattern.*) {
        .identifier => |n| {
            if (scope.lookupLocal(n) == null) try scope.declare(n, .undefined, true, true);
        },
        .array => |ap| {
            for (ap.elements) |el| if (el.target) |t| try hoistVarPattern(self, t, scope);
            if (ap.rest) |r| try hoistVarPattern(self, r, scope);
        },
        .object => |op| {
            for (op.properties) |prop| try hoistVarPattern(self, prop.target, scope);
            if (op.rest) |r| if (scope.lookupLocal(r) == null) try scope.declare(r, .undefined, true, true);
        },
    }
}

/// §14.3.2.1: the environment a `var` initializer's value lands in. A `var x = e` is `x = e`
/// (PutValue) on the running lexical env, so if that env chain crosses an Object Environment
/// Record (a `with`) before reaching the VariableEnvironment, the binding lands in the current
/// scope (where the with-body's closures resolve it); otherwise it targets the var scope (where
/// `hoistVarNames` instantiated it). Using `declare` here (not a direct binding write) refreshes a
/// mutable binding even over an immutable global value property (`var NaN = 1` in sloppy code).
pub fn varInitTarget(env: *Environment) *Environment {
    var e: *Environment = env;
    while (true) {
        if (e.with_object != null) return env; // lexically inside a `with` → current scope
        if (e.is_var_scope) return e; // reached the VariableEnvironment
        e = e.parent orelse return e;
    }
}

/// True iff a `with` object Environment Record sits between `env` and the nearest
/// VariableEnvironment — i.e. a `var x = e` initializer's PutValue could resolve `x` through a
/// binding object (§14.3.2.3). Only then do we route the var initializer through `assignToTarget`.
pub fn varInWithReach(env: *Environment) bool {
    var e: *Environment = env;
    while (true) {
        if (e.with_object != null) return true;
        if (e.is_var_scope) return false;
        e = e.parent orelse return false;
    }
}

/// Does `env`'s lexical chain (to the root) contain a `with` object Environment Record? Used at
/// function-call setup to re-arm the dynamic `with_depth` gate for a closure captured inside a
/// `with` — its free names must resolve through the captured binding object(s) even though the
/// `with` statement is no longer on the dynamic stack (§9.1.2.2 / §13.11.7).
pub fn envHasWith(env: *Environment) bool {
    var e: ?*Environment = env;
    while (e) |cur| {
        if (cur.with_object != null) return true;
        e = cur.parent;
    }
    return false;
}

pub fn runBlock(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!Completion {
    var last: Completion = .{ .normal = .undefined };
    for (stmts) |s| {
        last = try self.evalStmt(s, env);
        if (last.isAbrupt()) return last;
    }
    return last;
}

/// Run a StatementList that forms its OWN lexical scope (a Block, or a try / catch / finally
/// body), applying the §ER DisposeResources epilogue when it lexically contains a `using` / `await
/// using`. Gated on `blockHasUsing` so an ordinary scope is identical to a bare `runBlock` (perf:
/// no dispose-stack traffic for ordinary scope exit).
pub fn runScope(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!Completion {
    // §14.2.3 BlockDeclarationInstantiation (lexical step): hoist this block's top-level
    // `let`/`const`/`class` names as TDZ bindings before running it. `runScope` is entered only for a
    // block that actually has lexical declarations (or a try/catch/finally body), so the hot path
    // (declaration-free blocks via `runBlock`) never reaches here.
    try self.hoistLexicalNames(stmts, env);
    // §14.2.3 (function step): instantiate this block's top-level FunctionDeclarations as initialized
    // closures bound in the block's OWN scope before it runs — so a forward reference inside the
    // block (`{ f(); function f(){} }`) resolves and the binding is block-scoped (does not leak).
    try hoistFunctionDeclarations(self, stmts, env);
    if (!blockHasUsing(stmts)) return runBlock(self, stmts, env);
    const marker = self.disposables.items.len;
    const c = try runBlock(self, stmts, env);
    return self.disposeFrom(marker, c);
}

/// §14.7.4 ForStatement body — the init/cond/body/update loop (the `using`-head dispose epilogue,
/// when present, is applied by the caller around this). Returns the loop's completion; a `break`
/// targeting this loop is consumed (→ normal), other abrupt completions propagate.
pub fn runForBody(self: *Interpreter, s: anytype, loop_env: *Environment, my_labels: []const []const u8) EvalError!Completion {
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
            .normal => {}, // fall through to the update
            .cont => |l| if (!loopHandles(l, my_labels)) return bc, // for our loop: fall through to update
            .brk => |l| if (loopHandles(l, my_labels)) break else return bc,
            .ret, .throw => return bc,
        }
        if (s.update) |u| {
            const uc = try self.evalExpr(u, loop_env);
            if (uc.isAbrupt()) return uc;
        }
    }
    return .{ .normal = .undefined };
}

/// §14.7.5 `for (HEAD in EXPR)` — ForIn/OfHeadEvaluation (enumerate) + ForIn/OfBodyEvaluation.
pub fn evalForIn(self: *Interpreter, s: anytype, env: *Environment, my_labels: []const []const u8) EvalError!Completion {
    // §14.7.5.6 step 7.a: a null/undefined operand → the body never runs (no throw).
    const rc = try self.evalExpr(s.right, env);
    if (rc.isAbrupt()) return rc;
    if (rc.normal == .undefined or rc.normal == .null) return .{ .normal = .undefined };
    // EnumerateObjectProperties — the enumerable string keys to visit (computed once up front;
    // mutations to the object during the loop are not reflected, an accepted M-subset simplification).
    var keys: std.ArrayListUnmanaged(Value) = .empty;
    const ek = try enumerateKeys(self, rc.normal, &keys);
    if (ek.isAbrupt()) return ek; // a Proxy ownKeys/getOwnPropertyDescriptor trap may throw
    for (keys.items) |k| {
        const hb = try bindForHead(self, s.head, k, env);
        if (hb.completion.isAbrupt()) return hb.completion;
        const bc = try self.evalStmt(s.body.*, hb.env);
        switch (bc) {
            .normal => {},
            .cont => |l| if (!loopHandles(l, my_labels)) return bc,
            .brk => |l| if (loopHandles(l, my_labels)) break else return bc,
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
pub fn evalForOf(self: *Interpreter, s: anytype, env: *Environment, my_labels: []const []const u8) EvalError!Completion {
    const rc = try self.evalExpr(s.right, env);
    if (rc.isAbrupt()) return rc;
    const git = try self.getIterator(rc.normal);
    const iterator = switch (git) {
        .abrupt => |c| return c,
        .iterator => |it| it,
    };
    // §ER: a `for (using x of …)` head disposes the iterated resource at the END OF EACH ITERATION.
    const head_uses = s.head == .decl and (s.head.decl.kind == .using_decl or s.head.decl.kind == .await_using_decl);
    while (true) {
        try self.tick(); // §reliability: an infinite iterable terminates via the step watchdog, never hangs
        const step = try self.iteratorStep(iterator);
        const v = switch (step) {
            .abrupt => |c| return c, // a throwing next() — already an abrupt completion
            .done => break,
            .value => |val| val,
        };
        const marker = self.disposables.items.len;
        const hb = try bindForHead(self, s.head, v, env);
        if (hb.completion.isAbrupt()) {
            const after = try self.disposeFrom(marker, hb.completion); // dispose any pushed before the throw
            try self.iteratorClose(iterator); // §7.4.11 abrupt binding → close the iterator
            return after;
        }
        var bc = try self.evalStmt(s.body.*, hb.env);
        // §ER DisposeResources at end of iteration (normal OR abrupt), before the iterator-close logic.
        if (head_uses) bc = try self.disposeFrom(marker, bc);
        switch (bc) {
            .normal => {},
            .cont => |l| {
                // A `continue` for our loop steps to the next value; a labelled one for an outer
                // loop is an abrupt exit of THIS loop — a NORMAL completion close (§7.4.11): a
                // throwing `return()` propagates.
                if (!loopHandles(l, my_labels)) {
                    const cc = try self.iteratorCloseChecked(iterator);
                    if (cc.isAbrupt()) return cc;
                    return bc;
                }
            },
            .brk => |l| {
                // §14.7.5.7 step 11.b.iii: break closes the iterator on a NORMAL completion — a
                // throwing `return()` (or non-object result) propagates (§7.4.11 steps 5–6).
                const cc = try self.iteratorCloseChecked(iterator);
                if (cc.isAbrupt()) return cc;
                if (loopHandles(l, my_labels)) break else return bc; // outer-targeted break still propagates
            },
            .ret => {
                // §7.4.11: a `return` completion is NOT a throw → propagate a throwing `return()`.
                const cc = try self.iteratorCloseChecked(iterator);
                if (cc.isAbrupt()) return cc;
                return bc;
            },
            .throw => {
                // §7.4.11 step 4: on a throw completion the original error wins — `return()`'s
                // own error is swallowed.
                try self.iteratorClose(iterator);
                return bc;
            },
        }
    }
    return .{ .normal = .undefined };
}

/// §14.7.5.6 ForIn/OfBodyEvaluation with the `async` iteration hint — `for await (HEAD of EXPR) BODY`.
/// GetIterator(EXPR, async): use `EXPR[Symbol.asyncIterator]()` if present, else wrap the sync
/// iterator in an AsyncFromSyncIterator (§27.1.4). Each iteration AWAITs `iterator.next()` (and the
/// async-from-sync wrapper also awaits each value), binds the value, runs the body; an abrupt
/// completion closes the iterator with an awaited `return` (§7.4.11 AsyncIteratorClose). Runs only on
/// an async body thread (`current_gen.is_async`), guaranteed by the parser's async-context check.
pub fn evalForAwaitOf(self: *Interpreter, s: anytype, env: *Environment, my_labels: []const []const u8) EvalError!Completion {
    const rc = try self.evalExpr(s.right, env);
    if (rc.isAbrupt()) return rc;
    const ait = try self.getAsyncIterator(rc.normal);
    const iterator: *Object = switch (ait) {
        .abrupt => |c| return c,
        .iterator => |it| it,
    };
    while (true) {
        try self.tick(); // §reliability: an infinite async iterable terminates via the step watchdog, never hangs
        // §14.7.5.6 step 3.b: result ← Await( IteratorNext(iterator) ). An async iterator's `next`
        // returns a promise of the IteratorResult; await it, then decode `{value, done}`.
        const raw = try interp_async.iteratorCallRaw(self, iterator, "next", .undefined, false);
        if (raw.isAbrupt()) return raw;
        const aw = try interp_async.doAwait(self, raw.normal);
        if (aw.isAbrupt()) return aw; // a rejected `next` promise throws into the body
        const decoded = try interp_async.iterResultFromValue(self, aw.normal);
        const step: IterStep = switch (decoded) {
            .abrupt => |c| return c,
            .result => |r| r,
        };
        if (step.done) break; // §14.7.5.6: done → finish the loop
        const v = step.value;
        const hb = try bindForHead(self, s.head, v, env);
        if (hb.completion.isAbrupt()) {
            try asyncIteratorClose(self, iterator);
            return hb.completion;
        }
        const bc = try self.evalStmt(s.body.*, hb.env);
        switch (bc) {
            .normal => {},
            .cont => |l| {
                if (!loopHandles(l, my_labels)) {
                    try asyncIteratorClose(self, iterator);
                    return bc;
                }
            },
            .brk => |l| {
                try asyncIteratorClose(self, iterator);
                if (loopHandles(l, my_labels)) break else return bc;
            },
            .ret, .throw => {
                try asyncIteratorClose(self, iterator);
                return bc;
            },
        }
    }
    return .{ .normal = .undefined };
}

/// §7.4.11 AsyncIteratorClose — best-effort: call `iterator.return()`, AWAIT its (promise) result,
/// and ignore it (the original completion wins). A missing/non-callable `return` is a no-op. Runs on
/// the async body thread (so `await` is available).
pub fn asyncIteratorClose(self: *Interpreter, iterator: *Object) EvalError!void {
    const rc = try self.getProperty(.{ .object = iterator }, "return");
    if (rc.isAbrupt()) return; // swallow
    if (rc.normal != .object or rc.normal.object.kind != .function) return;
    const inner = self.callFunction(rc.normal.object, &.{}, .{ .object = iterator }) catch return;
    if (inner.isAbrupt()) return; // swallow a throwing return
    // Await the (possibly promise) result so a pending close settles before the loop unwinds.
    _ = interp_async.doAwait(self, inner.normal) catch return;
}

/// §14.7.5.7 ForIn/OfBodyEvaluation: bind/assign one item to the loop head, returning the
/// environment the body runs in (plus any abrupt completion from an assignment-target write). A
/// `let`/`const` head gets a FRESH per-iteration `Environment` (CreatePerIterationEnvironment), so
/// each iteration's binding is independent (closures capture distinct values). A `var` declaration
/// or an assignment-target head writes into / through `env`.
pub fn bindForHead(self: *Interpreter, head: ast.ForHead, item: Value, env: *Environment) EvalError!HeadBinding {
    switch (head) {
        .decl => |d| {
            const is_using = d.kind == .using_decl or d.kind == .await_using_decl;
            const mutable = d.kind != .const_decl and !is_using;
            // §14.7.5.7: a `var` head writes the iterated value into the hoisted VariableEnvironment
            // binding (visible after the loop); the body still runs in the loop env `env` (no
            // per-iteration scope). let/const/using instead get a FRESH per-iteration scope.
            if (d.kind == .var_decl) {
                const vs = varInitTarget(env);
                if (d.target.* == .identifier) {
                    try vs.declare(d.target.identifier, item, true, true);
                } else {
                    const bc = try interp_destr.bindPattern(self, d.target, item, vs, true);
                    if (bc.isAbrupt()) return .{ .env = env, .completion = bc };
                }
                return .{ .env = env };
            }
            const target_env = try Environment.create(self.arena, env);
            // §ER: a `for (using x of …)` head registers the iterated value as a DisposableResource
            // (disposed at the end of each iteration by `evalForOf`). A non-callable @@dispose throws.
            if (is_using) {
                const pc = try interp_ops.disposePush(self, item, d.kind == .await_using_decl);
                if (pc.isAbrupt()) return .{ .env = env, .completion = pc };
            }
            if (d.target.* == .identifier) {
                try target_env.declare(d.target.identifier, item, mutable, true);
            } else {
                const bc = try interp_destr.bindPattern(self, d.target, item, target_env, mutable);
                if (bc.isAbrupt()) return .{ .env = env, .completion = bc };
            }
            return .{ .env = target_env };
        },
        .target => |t| {
            // §14.7.5.6 ForIn/OfBodyEvaluation (lhsKind = assignment): an ArrayLiteral / ObjectLiteral
            // head is an AssignmentPattern — DestructuringAssignmentEvaluation (§13.15.5.2), which runs
            // its own §7.4 IteratorClose on an abrupt element/default. A simple target is a PutValue.
            const wc = switch (t.*) {
                .array_literal, .object_literal => try interp_destr.assignPattern(self, t, item, env),
                else => try assignToTarget(self, t, item, env),
            };
            return .{ .env = env, .completion = if (wc.isAbrupt()) wc else .{ .normal = .undefined } };
        },
    }
}

/// §6.2.5.6 PutValue step 6.a / §9.1.1.4.16 + §9.1.1.1.3: an assignment to an UNRESOLVED
/// IdentifierReference. In STRICT mode this is a ReferenceError; in SLOPPY mode it performs
/// `Set(globalObject, name, value, false)`, which — when the property is absent — creates an
/// ordinary {writable, enumerable, configurable} own property on the global object. We keep the
/// engine's two views of the global namespace consistent: the property is written on BOTH the
/// reified global object (so `globalThis.x` sees it) AND the global declarative Environment (so a
/// bare `x` resolves to it). Returns the assigned value. SLOW path only — a resolved binding never
/// reaches here, so the hot assignment path is unchanged.
pub fn assignUnresolved(self: *Interpreter, name: []const u8, value: Value) EvalError!Completion {
    if (self.strict) return self.throwError("ReferenceError", name);
    const g = self.globals orelse return self.throwError("ReferenceError", name);
    // Mirror onto the reified global object (`globalThis`). `set` honors an existing non-writable
    // property (a no-op write, per Set(..., false)); otherwise it creates a default data property.
    if (g.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        try gb.value.object.set(name, value);
    };
    // Reflect in the global Environment so bare-identifier resolution sees the same value.
    if (g.lookup(name)) |b| {
        if (b.mutable) b.value = value;
    } else {
        try g.declare(name, value, true, true);
    }
    return .{ .normal = value };
}

/// §6.2.5.6 PutValue for an identifier reference — the with-aware ResolveBinding + SetMutableBinding
/// used by AssignmentExpression, compound/update assignment, and `var x = e` initializers inside a
/// `with`. When `with_depth > 0` the reference is resolved through any enclosing `with` object's
/// object Environment Record (HasBinding consults HasProperty over the proto chain) before falling
/// back to lexical bindings; an unresolved write creates/sets a global per §6.2.5.6 step 5.b.
pub fn putWithAwareIdentifier(self: *Interpreter, name: []const u8, value: Value, env: *Environment) EvalError!Completion {
    if (self.with_depth > 0) switch (resolveIdRef(self, env, name)) {
        .with_object => |o| return self.setProperty(.{ .object = o }, name, value),
        .binding => |b| {
            if (!b.initialized) return self.throwError("ReferenceError", name); // §13.x TDZ
            if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
            b.value = value;
            return .{ .normal = value };
        },
        .unresolved => return assignUnresolved(self, name, value),
    };
    const b = env.lookup(name) orelse return assignUnresolved(self, name, value);
    if (!b.initialized) return self.throwError("ReferenceError", name); // §13.x PutValue to a TDZ binding
    if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
    b.value = value;
    return .{ .normal = value };
}

/// §6.2.5.6 PutValue — write `value` through the AssignmentTarget `node` (identifier / `a.b` /
/// `a[k]`). Mirrors the `assign`/`assign_member`/`assign_index` evaluation paths.
pub fn assignToTarget(self: *Interpreter, node: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
    switch (node.*) {
        .identifier => |name| return putWithAwareIdentifier(self, name, value, env),
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
pub fn enumerateKeys(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
    var seen: std.StringHashMapUnmanaged(void) = .{};
    switch (value) {
        .object => |start| {
            var obj: ?*Object = start;
            while (obj) |o| {
                // §10.5.11/§14.7.5: a Proxy enumerates via its [[OwnPropertyKeys]] (the `ownKeys`
                // trap or forwarded), filtered by each key's [[GetOwnProperty]] enumerable flag.
                // Its own `properties`/`array` stores are empty, so it MUST take this trap path.
                if (o.proxy) |pd| {
                    const pc = try enumerateProxyKeys(self, pd, &seen, out);
                    if (pc.isAbrupt()) return pc;
                    obj = switch (try self.ordinaryGetPrototypeOf(o)) {
                        .proto => |p| p,
                        .abrupt => |c| return c,
                    };
                    continue;
                }
                // Stop at a realm built-in prototype: its properties are spec-non-enumerable.
                if (isBuiltinProto(self, o)) break;
                // Array exotic integer indices (numeric order), then ordinary string keys. `length`
                // is never enumerated (it is not stored in `properties`).
                if (o.kind == .array) {
                    for (try o.arrayIndices(self.arena)) |i| {
                        const key = try numberToString(self.arena, @floatFromInt(i));
                        if (seen.contains(key)) continue;
                        try seen.put(self.arena, key, {});
                        try out.append(self.arena, .{ .string = key });
                    }
                }
                // §10.1.11.1 OrdinaryOwnPropertyKeys order: integer-index keys ascending, then
                // the rest in insertion order (the ArrayHashMap iterator alone yields pure
                // insertion order, which mis-orders out-of-order integer keys like `o[2]=…;o[0]=…`).
                for (try o.orderedStringKeys(self.arena)) |key| {
                    if (seen.contains(key)) continue;
                    try seen.put(self.arena, key, {}); // a shadowed name is skipped even if non-enumerable here
                    const pv = o.properties.get(key) orelse continue;
                    if (!pv.enumerable) continue; // §14.7.5: only enumerable own keys
                    try out.append(self.arena, .{ .string = key });
                }
                obj = o.prototype;
            }
        },
        .string => |s| {
            // §22.1: a primitive String boxes to character-index own properties (enumerable) —
            // one per UTF-16 code unit (§6.1.4).
            for (0..sutf16.utf16Length(s)) |i| {
                const key = try numberToString(self.arena, @floatFromInt(i));
                try out.append(self.arena, .{ .string = key });
            }
        },
        else => {}, // §13.5 ToObject of a number/boolean → no own enumerable string keys (M-subset)
    }
    return .{ .normal = .undefined };
}

/// §14.7.5/§10.5.11: enumerate one Proxy's own enumerable STRING keys. Calls the proxy's
/// [[OwnPropertyKeys]] (ownKeys trap or forwarded), skips Symbol keys and already-seen names, and
/// keeps a key only if its [[GetOwnProperty]] reports `enumerable: true`. A trap throw propagates.
fn enumerateProxyKeys(
    self: *Interpreter,
    pd: *ProxyData,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(Value),
) EvalError!Completion {
    const kc = try builtin_proxy.ownKeys(self, pd);
    if (kc.isAbrupt()) return kc;
    if (kc.normal != .object) return .{ .normal = .undefined };
    const arr = kc.normal.object;
    const n = arr.arrayLen();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const kv = arr.arrayGet(i);
        if (kv != .string) continue; // §14.7.5 step 6.b: Symbol keys are not enumerated
        const key = kv.string;
        if (seen.contains(key)) continue;
        try seen.put(self.arena, key, {}); // a shadowed name is fixed at the first occurrence
        // [[GetOwnProperty]] for the enumerable flag (and to honor an absent / non-enumerable prop).
        const dc = try builtin_proxy.getOwnProperty(self, pd, kv);
        if (dc.isAbrupt()) return dc;
        if (dc.normal != .object) continue; // undefined → not enumerated
        const en = dc.normal.object.get("enumerable") orelse continue;
        if (en == .boolean and en.boolean) try out.append(self.arena, kv);
    }
    return .{ .normal = .undefined };
}

/// Is `o` one of the realm's built-in prototype objects (`Object`/`Array`/`String`/Error-family
/// `.prototype`)? Their properties are spec-non-enumerable; for-in stops the chain walk at them.
/// Pointer-identity against the constructors seeded in `globals` (the global names map to native
/// constructors whose `.prototype` is the prototype object). A null `globals` (unit-test direct
/// eval) yields false — harmless, as those tests don't enumerate built-in protos.
pub fn isBuiltinProto(self: *Interpreter, o: *Object) bool {
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

/// Run a sequence of statements (a static block / function body) in `env`, returning the first
/// abrupt completion (a `throw` propagates; `return`/`break`/`continue` are not produced at the
/// top of a static block body in the M-subset). Used by §15.7.11 ClassStaticBlock evaluation.
pub fn runBlockBody(self: *Interpreter, body: []const ast.Stmt, env: *Environment) EvalError!Completion {
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
