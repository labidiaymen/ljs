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
const builtins = @import("builtins.zig");
const bigint = @import("bigint.zig");
const Parser = @import("parser.zig").Parser;

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
const numToInt32 = ops.numberToInt32;
const numToUint32 = ops.numberToUint32;

pub const EvalError = error{ StepLimitExceeded, OutOfMemory };

/// Test262 `[async]` completion state, written by the runner-injected `$DONE` native (`test_done`) and
/// read by the runner after draining the Job queue. `called` distinguishes "never called" (→ fail:
/// the async test never reported) from a real outcome; `failed` is true iff `$DONE` was called with a
/// truthy argument (→ async fail), false for no/undefined/falsy (→ async pass). Not part of ECMA-262.
pub const AsyncDone = struct {
    called: bool = false,
    failed: bool = false,
    /// The string form of the failure argument (for diagnostics), valid when `failed`.
    message: []const u8 = "",
};

/// §ER CreateDisposableResource result — a resource value plus its dispose method (and the hint:
/// `is_async` ⇒ `@@asyncDispose`, awaited at disposal). `method == null` only for a null/undefined
/// resource (a no-op at disposal). `value` is the `this` passed to `method`.
pub const DisposableResource = struct {
    value: Value,
    method: ?*Object,
    is_async: bool,
};

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
    /// §13.3.7 / §9.3.3 [[ThisBindingStatus]]: a per-`this`-binding "initialized" cell, or null when the
    /// active binding is always-initialized (ordinary functions, base constructors, global/eval). A
    /// DERIVED class constructor allocates a cell starting `false` (TDZ) that `super(...)` flips to true;
    /// reading `this` (or a derived ctor returning undefined) while false is a ReferenceError, and a
    /// second `super()` while true is too. An ARROW captures the enclosing cell LEXICALLY (so a `super()`
    /// in an IIFE arrow targets the constructor's binding even when invoked from an unrelated method —
    /// e.g. via an iterator's `return()` during a `for-of` abrupt completion), not the dynamic caller's.
    this_init_cell: ?*bool = null,
    /// §9.2.5 / §13.3.5 the active function's [[HomeObject]] — set when a class/object method is
    /// invoked (to its `home_object`), null otherwise. `super.x` resolves against
    /// `home_object.[[Prototype]]`; `super(...)` invokes `home_object`'s constructor's superclass.
    /// Saved/restored around each [[Call]] alongside `this_val`.
    home_object: ?*Object = null,
    /// §13.3.12 the active function's [[NewTarget]] — the constructor when the running function was
    /// invoked via `new` / a `super(...)` chain (set in `construct`), else `undefined` (cleared for an
    /// ordinary `[[Call]]`). The `new.target` MetaProperty reads it. Saved/restored around each
    /// [[Call]] alongside `this_val` / `home_object`; arrows inherit it lexically (they don't reset it).
    new_target: Value = .undefined,
    /// The [[NewTarget]] to install for the NEXT non-arrow `callFunction` body. `construct` sets it to
    /// the constructor right before invoking the body; `callFunction` consumes it into `new_target` and
    /// resets it to `undefined` so an ordinary call (and nested ordinary calls within the body) sees
    /// `undefined`. A one-shot hand-off that avoids threading a parameter through 39 call sites.
    pending_new_target: Value = .undefined,
    /// The [[NewTarget]] visible to the NEXT `callNative` — `callFunction` copies the one-shot
    /// `pending_new_target` here just before dispatching a native, so a built-in *constructor* reached
    /// through a `super(...)` chain (e.g. `class X extends Map { constructor(){ super() } }`) can tell
    /// it is being CONSTRUCTED (initialize the instance) vs plainly CALLED (`Map()` → TypeError). The
    /// top-level `new` path never needs it (handled in `constructNT` before any native dispatch).
    native_new_target: Value = .undefined,
    /// §21.3.2.27 Math.random RNG state — a fixed-seed xorshift64* (this is a DETERMINISTIC engine and
    /// the Zig sandbox blocks host RNG / `Date.now`, so no entropy source exists). Test262's random
    /// tests only require the result be a Number in [0,1); the fixed seed keeps the engine reproducible.
    rng_state: u64 = 0x9E3779B97F4A7C15,
    /// The realm's global environment — used to resolve the Error family for engine-thrown
    /// errors (so they carry the right prototype + name). Set by the engine after setup.
    globals: ?*Environment = null,
    /// §20.4.2.2 the GlobalSymbolRegistry — `Symbol.for(key)` returns the same Symbol for a given key
    /// string (creating it on first use). Lives for the realm's lifetime (arena-allocated).
    symbol_registry: std.StringHashMapUnmanaged(*Symbol) = .{},
    /// §11.2.2 the running execution context's strict-mode flag. Set from the Script's strictness on
    /// `run`, and saved/restored to the active function's `FunctionData.strict` around each body
    /// (`callFunction`). Gates §6.2.5.6 PutValue to an UNRESOLVED IdentifierReference: in sloppy mode
    /// it creates a property on the global object (§9.1.1.4.16 step "global, var-create"); in strict
    /// mode it throws ReferenceError. Only the slow (unresolved) assignment path reads it — a resolved
    /// binding's mutation never consults it, so the hot assignment path is unchanged.
    strict: bool = false,
    /// §14.11 count of `with` statements currently on the scope chain. When 0 (the overwhelming
    /// common case) identifier resolution takes the fast declarative path unchanged; when >0,
    /// resolution consults object Environment Records (the `with` binding objects) first.
    with_depth: u32 = 0,
    /// §27.5 the generator whose body THIS interpreter is currently executing (set on the per-generator
    /// body interpreter spawned for a `function*`; null for the main interpreter and ordinary calls).
    /// A `yield` is legal only when this is non-null; evaluating `yield x` reaches the handoff via it.
    current_gen: ?*object_mod.Generator = null,
    /// All generators created in this realm (tracked on the MAIN interpreter only, via `gen_registry`).
    /// At realm teardown `cleanupGenerators` signals any still-parked body thread to unwind and joins
    /// it, so a never-fully-consumed generator does not leave a lingering OS thread. The body
    /// interpreters share the same registry pointer.
    gen_registry: ?*std.ArrayListUnmanaged(*object_mod.Generator) = null,
    /// §9.5 the realm's Job (microtask) queue — a FIFO of PromiseReaction / PromiseResolveThenable jobs
    /// enqueued by Promise settlement / resolution (HostEnqueuePromiseJob). The engine drains it once
    /// the synchronous execution stack is empty (`drainJobs`). Shared (pointer) across the main and
    /// async-body interpreters so a job enqueued on a body thread reaches the same queue. Null in a
    /// realm-less unit eval (no promises → no jobs). The drain is bounded by the step limit (no hangs).
    job_queue: ?*std.ArrayListUnmanaged(object_mod.Job) = null,
    /// Test262 async completion sink — the runner injects a `$DONE(err)` global (native `test_done`)
    /// for `[async]` tests; calling it records the outcome here, which the runner reads after draining
    /// the Job queue (no arg / falsy → async pass; truthy → async fail). Shared (pointer) across the
    /// main + async-body interpreters so a `$DONE` from inside a `.then` job is observed. Null for
    /// ordinary evaluation (no `$DONE` installed → never written).
    async_done: ?*AsyncDone = null,
    /// The process-global threaded Io — supplies the raw-OS-futex backing `std.Io.Semaphore.wait/post`
    /// for the generator ping-pong handoff. `global_single_threaded` spins up no thread pool (futex ops
    /// are pool-independent), so this is free for ordinary (non-generator) execution.
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    /// §14.13 the label name(s) that apply to the statement about to be evaluated — populated by
    /// `labeled_stmt` (a chain `a: b: stmt` leaves `["a","b"]` here), consumed by an iteration
    /// statement which snapshots them as its own labels and clears this back to empty before running
    /// its body. Empty for every unlabeled statement (the hot-loop fast path: a label-less `break`/
    /// `continue` against an empty label set needs no comparison).
    pending_labels: std.ArrayListUnmanaged([]const u8) = .empty,

    /// §ER DisposeCapability — the per-interpreter stack of DisposableResource records pushed by
    /// `using` / `await using` declarations, a LIFO. A scope (Block / FunctionBody / for-loop /
    /// for-of iteration) that lexically contains a `using` snapshots `disposables.items.len` on entry
    /// and, at exit (normal OR abrupt), runs `disposeFrom(marker, completion)` to dispose every
    /// resource pushed since (in reverse order) and pop them. A scope with NO `using` never grows this
    /// stack, so its exit pays a single length-compare (perf gate: ordinary block exit is unchanged).
    /// Per-interpreter (not shared): each generator/async body interpreter runs one-at-a-time and its
    /// `using` scopes open + close entirely within that body, so its own stack suffices.
    disposables: std.ArrayListUnmanaged(DisposableResource) = .empty,

    /// §14.9/§14.8: is an abrupt `.brk`/`.cont` completion (carrying `comp_label`) targeted at a loop
    /// whose applicable labels are `my_labels`? An unlabeled completion (`comp_label == null`) targets
    /// the innermost loop (always a match); a labelled one matches only if its label is among `my_labels`.
    inline fn loopHandles(comp_label: ?[]const u8, my_labels: []const []const u8) bool {
        const lbl = comp_label orelse return true; // unlabeled → innermost loop catches it
        for (my_labels) |m| if (std.mem.eql(u8, m, lbl)) return true;
        return false;
    }

    /// Snapshot the labels applying to the iteration/switch statement now being evaluated and clear
    /// `pending_labels` (so the statement's own body inherits no labels). Hot-loop fast path: an
    /// unlabeled loop sees an empty set and returns an empty slice with no allocation. A labelled loop
    /// dupes the names into the arena (the live buffer may be mutated by nested labelled statements).
    fn takeLabels(self: *Interpreter) []const []const u8 {
        const n = self.pending_labels.items.len;
        if (n == 0) return &.{};
        const out = self.arena.dupe([]const u8, self.pending_labels.items) catch &.{};
        self.pending_labels.clearRetainingCapacity();
        return out;
    }

    pub fn run(self: *Interpreter, program: ast.Program, env: *Environment) EvalError!Completion {
        // §11.2.2: the Script (or eval) body runs in its declared strict context (a `"use strict"`
        // prologue, a strict `RunMode`, or — for a direct eval — strictness inherited from the caller,
        // already folded into `program.strict` by the parser). Gates §6.2.5.6 PutValue to an unresolved
        // name. Saved/restored so an eval's body strictness does not leak back into the caller's frame.
        const saved_strict = self.strict;
        self.strict = program.strict;
        defer self.strict = saved_strict;
        // §16.1.7 / §19.2.1.3 Global/EvalDeclarationInstantiation (lexical step): hoist this Script/eval
        // body's top-level `let`/`const`/`class` names into the env as TDZ bindings before any statement
        // runs, so a forward reference is a §13.x ReferenceError (not a stray global / outer resolution).
        try self.hoistLexicalNames(program.statements, env);
        // §16.1.7/§19.2.1.3 (var step): instantiate the Script/eval body's VarDeclaredNames in the
        // VariableEnvironment (the global env, or for a direct eval the eval scope — both var scopes).
        try self.hoistVarNames(program.statements, env.varScope());
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
        // §14.13: the label(s) applying to THIS statement (set by an enclosing `labeled_stmt`) belong
        // to this statement alone — capture them and clear `pending_labels` so they don't leak into any
        // nested statement (e.g. `L: { for(;;)… }` — `L` labels the block, NOT the inner loop). Only an
        // iteration/switch statement uses `my_labels`; the hot path (no label) takes an empty slice.
        const my_labels = self.takeLabels();
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
                        const pc = try self.disposePush(v, d.kind == .await_using_decl);
                        if (pc.isAbrupt()) return pc;
                    }
                    // §10.2.11: a `var` binds into the nearest VariableEnvironment (where `hoistVarNames`
                    // instantiated it) — or the current scope if lexically inside a `with`; let/const/using
                    // bind in the current scope. The fast path skips pattern matching for an identifier.
                    const is_var = d.kind == .var_decl;
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
                        const bc = try self.bindPattern(dec.target, v, target_env, mutable);
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
                if (blockNeedsScope(stmts)) return self.runScope(stmts, try Environment.create(self.arena, env));
                return self.runBlock(stmts, env);
            },
            .func_decl => |f| {
                // §15.2 — bind a function object to its name in the current scope.
                const obj = try Object.createFunction(self.arena, .{ .params = f.params, .rest = f.rest, .body = f.body, .closure = env, .is_generator = f.is_generator, .is_async = f.is_async, .strict = f.strict });
                obj.prototype = self.functionProto(); // §20.2.3 so `f.call`/`.apply`/`.bind` resolve
                // §20.2.4.1/.2: a declaration always has a name; install `length` + `name`.
                try setFunctionLength(obj, paramCount(f.params));
                try self.setFunctionName(obj, f.name orelse "", "");
                try setConstructorBackref(obj); // §10.2.4 MakeConstructor: F.prototype.constructor === F
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
                    const lc = try self.runForBody(s, loop_env, my_labels);
                    return self.disposeFrom(marker, lc);
                }
                return self.runForBody(s, loop_env, my_labels);
            },
            .for_in_stmt => |s| return self.evalForIn(s, env, my_labels),
            .for_of_stmt => |s| return if (s.is_await) self.evalForAwaitOf(s, env, my_labels) else self.evalForOf(s, env, my_labels),
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
                var result = try self.runScope(s.block, try Environment.create(self.arena, env));
                if (result == .throw and s.catch_block != null) {
                    const catch_env = try Environment.create(self.arena, env);
                    // §14.15.2 CatchClauseEvaluation: BindingInitialization of the CatchParameter
                    // (BindingIdentifier or destructuring BindingPattern) with the thrown value. A throw
                    // raised by the binding (e.g. a non-iterable for `catch([a])`) replaces the original
                    // and skips the Catch Block — but `finally` below still runs.
                    var bound = true;
                    if (s.catch_param) |pat| {
                        const bc = try self.bindPattern(pat, result.throw, catch_env, true);
                        if (bc.isAbrupt()) {
                            result = bc;
                            bound = false;
                        }
                    }
                    if (bound) result = try self.runScope(s.catch_block.?, catch_env);
                }
                if (s.finally_block) |fb| {
                    const fc = try self.runScope(fb, try Environment.create(self.arena, env));
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
                        const bc = try self.runBlock(case.body, sw_env);
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

    /// §9.1.1.1 / §9.1.1.2 with-aware identifier resolution. Walks the scope chain consulting object
    /// Environment Records (the `with` binding objects, via `HasProperty`) and declarative records.
    /// ONLY used when `with_depth > 0`; the no-`with` path keeps the fast `env.lookup`. Returns the
    /// holding object (for a with binding), the declarative binding, or `.unresolved`.
    const IdRef = union(enum) { with_object: *Object, binding: *@import("environment.zig").Binding, unresolved };
    fn resolveIdRef(self: *Interpreter, env: *Environment, name: []const u8) IdRef {
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
    fn hoistLexicalNames(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!void {
        for (stmts) |s| switch (s) {
            .declaration => |d| {
                if (d.kind == .var_decl) continue; // §13.3.2 `var` is not a lexical (no TDZ here)
                for (d.decls) |dec| try self.hoistPatternNames(dec.target, env);
            },
            .class_decl => |c| {
                // §15.7: a ClassDeclaration introduces a lexical (let-like) binding for its name.
                if (c.name) |nm| if (env.lookupLocal(nm) == null)
                    try env.declare(nm, .undefined, true, false); // uninitialized → TDZ
            },
            else => {},
        };
    }

    /// Pre-declare every BindingIdentifier in a lexical-declaration pattern as uninitialized (TDZ).
    fn hoistPatternNames(self: *Interpreter, pattern: *const ast.Pattern, env: *Environment) EvalError!void {
        switch (pattern.*) {
            .identifier => |n| {
                if (env.lookupLocal(n) == null) try env.declare(n, .undefined, true, false);
            },
            .array => |ap| {
                for (ap.elements) |el| if (el.target) |t| try self.hoistPatternNames(t, env);
                if (ap.rest) |r| try self.hoistPatternNames(r, env);
            },
            .object => |op| {
                for (op.properties) |prop| try self.hoistPatternNames(prop.target, env);
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
    fn hoistVarNames(self: *Interpreter, stmts: []const ast.Stmt, scope: *Environment) EvalError!void {
        for (stmts) |s| try self.hoistVarNamesStmt(s, scope);
    }

    fn hoistVarNamesStmt(self: *Interpreter, stmt: ast.Stmt, scope: *Environment) EvalError!void {
        switch (stmt) {
            .declaration => |d| {
                if (d.kind == .var_decl) for (d.decls) |dec| try self.hoistVarPattern(dec.target, scope);
            },
            .block => |stmts| try self.hoistVarNames(stmts, scope),
            .if_stmt => |s| {
                try self.hoistVarNamesStmt(s.then.*, scope);
                if (s.otherwise) |e| try self.hoistVarNamesStmt(e.*, scope);
            },
            .while_stmt => |s| try self.hoistVarNamesStmt(s.body.*, scope),
            .do_while_stmt => |s| try self.hoistVarNamesStmt(s.body.*, scope),
            .for_stmt => |s| {
                if (s.init) |i| if (i.* == .declaration and i.declaration.kind == .var_decl)
                    for (i.declaration.decls) |dec| try self.hoistVarPattern(dec.target, scope);
                try self.hoistVarNamesStmt(s.body.*, scope);
            },
            .for_in_stmt => |s| {
                if (s.head == .decl and s.head.decl.kind == .var_decl) try self.hoistVarPattern(s.head.decl.target, scope);
                try self.hoistVarNamesStmt(s.body.*, scope);
            },
            .for_of_stmt => |s| {
                if (s.head == .decl and s.head.decl.kind == .var_decl) try self.hoistVarPattern(s.head.decl.target, scope);
                try self.hoistVarNamesStmt(s.body.*, scope);
            },
            .try_stmt => |s| {
                try self.hoistVarNames(s.block, scope);
                if (s.catch_block) |cb| try self.hoistVarNames(cb, scope);
                if (s.finally_block) |fb| try self.hoistVarNames(fb, scope);
            },
            .with_stmt => |s| try self.hoistVarNamesStmt(s.body.*, scope),
            .switch_stmt => |s| for (s.cases) |cs| try self.hoistVarNames(cs.body, scope),
            .labeled_stmt => |s| try self.hoistVarNamesStmt(s.body.*, scope),
            else => {},
        }
    }

    /// Declare each BindingIdentifier of a `var` pattern as an initialized `undefined` binding in
    /// `scope`, skipping names already bound (no-clobber). Unlike `hoistPatternNames` (lexical TDZ),
    /// `var` bindings are created already-initialized (§10.2.11).
    fn hoistVarPattern(self: *Interpreter, pattern: *const ast.Pattern, scope: *Environment) EvalError!void {
        switch (pattern.*) {
            .identifier => |n| {
                if (scope.lookupLocal(n) == null) try scope.declare(n, .undefined, true, true);
            },
            .array => |ap| {
                for (ap.elements) |el| if (el.target) |t| try self.hoistVarPattern(t, scope);
                if (ap.rest) |r| try self.hoistVarPattern(r, scope);
            },
            .object => |op| {
                for (op.properties) |prop| try self.hoistVarPattern(prop.target, scope);
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
    fn varInitTarget(env: *Environment) *Environment {
        var e: *Environment = env;
        while (true) {
            if (e.with_object != null) return env; // lexically inside a `with` → current scope
            if (e.is_var_scope) return e; // reached the VariableEnvironment
            e = e.parent orelse return e;
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

    /// Run a StatementList that forms its OWN lexical scope (a Block, or a try / catch / finally
    /// body), applying the §ER DisposeResources epilogue when it lexically contains a `using` / `await
    /// using`. Gated on `blockHasUsing` so an ordinary scope is identical to a bare `runBlock` (perf:
    /// no dispose-stack traffic for ordinary scope exit).
    fn runScope(self: *Interpreter, stmts: []const ast.Stmt, env: *Environment) EvalError!Completion {
        // §14.2.3 BlockDeclarationInstantiation (lexical step): hoist this block's top-level
        // `let`/`const`/`class` names as TDZ bindings before running it. `runScope` is entered only for a
        // block that actually has lexical declarations (or a try/catch/finally body), so the hot path
        // (declaration-free blocks via `runBlock`) never reaches here.
        try self.hoistLexicalNames(stmts, env);
        if (!blockHasUsing(stmts)) return self.runBlock(stmts, env);
        const marker = self.disposables.items.len;
        const c = try self.runBlock(stmts, env);
        return self.disposeFrom(marker, c);
    }

    /// §14.7.4 ForStatement body — the init/cond/body/update loop (the `using`-head dispose epilogue,
    /// when present, is applied by the caller around this). Returns the loop's completion; a `break`
    /// targeting this loop is consumed (→ normal), other abrupt completions propagate.
    fn runForBody(self: *Interpreter, s: anytype, loop_env: *Environment, my_labels: []const []const u8) EvalError!Completion {
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
    fn evalForIn(self: *Interpreter, s: anytype, env: *Environment, my_labels: []const []const u8) EvalError!Completion {
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
    fn evalForOf(self: *Interpreter, s: anytype, env: *Environment, my_labels: []const []const u8) EvalError!Completion {
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
            const hb = try self.bindForHead(s.head, v, env);
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
    fn evalForAwaitOf(self: *Interpreter, s: anytype, env: *Environment, my_labels: []const []const u8) EvalError!Completion {
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
            const raw = try self.iteratorCallRaw(iterator, "next", .undefined, false);
            if (raw.isAbrupt()) return raw;
            const aw = try self.doAwait(raw.normal);
            if (aw.isAbrupt()) return aw; // a rejected `next` promise throws into the body
            const decoded = try self.iterResultFromValue(aw.normal);
            const step: IterStep = switch (decoded) {
                .abrupt => |c| return c,
                .result => |r| r,
            };
            if (step.done) break; // §14.7.5.6: done → finish the loop
            const v = step.value;
            const hb = try self.bindForHead(s.head, v, env);
            if (hb.completion.isAbrupt()) {
                try self.asyncIteratorClose(iterator);
                return hb.completion;
            }
            const bc = try self.evalStmt(s.body.*, hb.env);
            switch (bc) {
                .normal => {},
                .cont => |l| {
                    if (!loopHandles(l, my_labels)) {
                        try self.asyncIteratorClose(iterator);
                        return bc;
                    }
                },
                .brk => |l| {
                    try self.asyncIteratorClose(iterator);
                    if (loopHandles(l, my_labels)) break else return bc;
                },
                .ret, .throw => {
                    try self.asyncIteratorClose(iterator);
                    return bc;
                },
            }
        }
        return .{ .normal = .undefined };
    }

    /// §7.4.11 AsyncIteratorClose — best-effort: call `iterator.return()`, AWAIT its (promise) result,
    /// and ignore it (the original completion wins). A missing/non-callable `return` is a no-op. Runs on
    /// the async body thread (so `await` is available).
    fn asyncIteratorClose(self: *Interpreter, iterator: *Object) EvalError!void {
        const rc = try self.getProperty(.{ .object = iterator }, "return");
        if (rc.isAbrupt()) return; // swallow
        if (rc.normal != .object or rc.normal.object.kind != .function) return;
        const inner = self.callFunction(rc.normal.object, &.{}, .{ .object = iterator }) catch return;
        if (inner.isAbrupt()) return; // swallow a throwing return
        // Await the (possibly promise) result so a pending close settles before the loop unwinds.
        _ = self.doAwait(inner.normal) catch return;
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
                        const bc = try self.bindPattern(d.target, item, vs, true);
                        if (bc.isAbrupt()) return .{ .env = env, .completion = bc };
                    }
                    return .{ .env = env };
                }
                const target_env = try Environment.create(self.arena, env);
                // §ER: a `for (using x of …)` head registers the iterated value as a DisposableResource
                // (disposed at the end of each iteration by `evalForOf`). A non-callable @@dispose throws.
                if (is_using) {
                    const pc = try self.disposePush(item, d.kind == .await_using_decl);
                    if (pc.isAbrupt()) return .{ .env = env, .completion = pc };
                }
                if (d.target.* == .identifier) {
                    try target_env.declare(d.target.identifier, item, mutable, true);
                } else {
                    const bc = try self.bindPattern(d.target, item, target_env, mutable);
                    if (bc.isAbrupt()) return .{ .env = env, .completion = bc };
                }
                return .{ .env = target_env };
            },
            .target => |t| {
                // §14.7.5.6 ForIn/OfBodyEvaluation (lhsKind = assignment): an ArrayLiteral / ObjectLiteral
                // head is an AssignmentPattern — DestructuringAssignmentEvaluation (§13.15.5.2), which runs
                // its own §7.4 IteratorClose on an abrupt element/default. A simple target is a PutValue.
                const wc = switch (t.*) {
                    .array_literal, .object_literal => try self.assignPattern(t, item, env),
                    else => try self.assignToTarget(t, item, env),
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
    fn assignUnresolved(self: *Interpreter, name: []const u8, value: Value) EvalError!Completion {
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

    /// §6.2.5.6 PutValue — write `value` through the AssignmentTarget `node` (identifier / `a.b` /
    /// `a[k]`). Mirrors the `assign`/`assign_member`/`assign_index` evaluation paths.
    fn assignToTarget(self: *Interpreter, node: *const ast.Node, value: Value, env: *Environment) EvalError!Completion {
        switch (node.*) {
            .identifier => |name| {
                if (self.with_depth > 0) switch (self.resolveIdRef(env, name)) {
                    .with_object => |o| return self.setProperty(.{ .object = o }, name, value),
                    .binding => |b| {
                        if (!b.initialized) return self.throwError("ReferenceError", name); // §13.x TDZ
                        if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                        b.value = value;
                        return .{ .normal = value };
                    },
                    .unresolved => return self.assignUnresolved(name, value),
                };
                const b = env.lookup(name) orelse return self.assignUnresolved(name, value);
                if (!b.initialized) return self.throwError("ReferenceError", name); // §13.x PutValue to a TDZ binding
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
                        for (try o.arrayIndices(self.arena)) |i| {
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
            .bigint => |b| return .{ .normal = .{ .bigint = b } }, // §12.9.3.2 BigIntLiteral
            .string => |s| return .{ .normal = .{ .string = s } },
            .boolean => |b| return .{ .normal = .{ .boolean = b } },
            .null => return .{ .normal = .null },
            .regex_literal => |r| return builtin_regexp.makeRegExp(self, r.pattern, r.flags), // §13.2.7
            .identifier => |name| {
                // §9.4.2 ResolveBinding + §6.2.5.5 GetValue + §9.1.1.1.6 GetBindingValue.
                if (self.with_depth > 0) switch (self.resolveIdRef(env, name)) {
                    .with_object => |o| return self.getProperty(.{ .object = o }, name),
                    .binding => |b| {
                        if (!b.initialized) return self.throwError("ReferenceError", name);
                        return .{ .normal = b.value };
                    },
                    .unresolved => return self.throwError("ReferenceError", name),
                };
                const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                if (!b.initialized) return self.throwError("ReferenceError", name); // TDZ (staged; see declaration note)
                return .{ .normal = b.value };
            },
            .assign => |a| {
                // §13.15.2 AssignmentExpression; mutation via §6.2.5.6 PutValue (identifier target).
                const c = try self.evalExpr(a.value, env);
                if (c.isAbrupt()) return c;
                // §13.15.2 / §8.4: `f = function(){}` (anonymous RHS, identifier LHS) → NamedEvaluation.
                try self.maybeSetAnonName(a.value, c.normal, a.name);
                if (self.with_depth > 0) switch (self.resolveIdRef(env, a.name)) {
                    .with_object => |o| return self.setProperty(.{ .object = o }, a.name, c.normal),
                    .binding => |b| {
                        if (!b.initialized) return self.throwError("ReferenceError", a.name); // §13.x TDZ
                        if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                        b.value = c.normal;
                        return .{ .normal = c.normal };
                    },
                    .unresolved => return self.assignUnresolved(a.name, c.normal),
                };
                const b = env.lookup(a.name) orelse return self.assignUnresolved(a.name, c.normal);
                if (!b.initialized) return self.throwError("ReferenceError", a.name); // §13.x PutValue to a TDZ binding
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
                // contributes a TRUE hole (it advances the index without defining the slot, so the
                // resulting array is sparse there: `1 in [1,,3]` is false, holes are skipped by
                // forEach/reduce/indexOf, etc.). A trailing elision the parser appended to mark `[...x,]`
                // (a valid literal trailing comma after a spread) is dropped here so it adds no slot.
                var list = elems;
                if (list.len >= 2 and list[list.len - 1].* == .elision and list[list.len - 2].* == .spread) {
                    list = list[0 .. list.len - 1];
                }
                const arr = try Object.createArray(self.arena, self.arrayProto());
                var idx: usize = 0;
                for (list) |n| {
                    if (n.* == .elision) {
                        idx += 1; // hole — leave the slot undefined/absent
                        continue;
                    }
                    if (n.* == .spread) {
                        const sc = try self.evalExpr(n.spread, env);
                        if (sc.isAbrupt()) return sc;
                        var tmp: std.ArrayListUnmanaged(Value) = .empty;
                        const ic = try self.iterateToList(sc.normal, &tmp);
                        if (ic.isAbrupt()) return ic;
                        for (tmp.items) |v| {
                            try arr.arraySet(self.arena, idx, v);
                            idx += 1;
                        }
                        continue;
                    }
                    const c = try self.evalExpr(n, env);
                    if (c.isAbrupt()) return c;
                    try arr.arraySet(self.arena, idx, c.normal);
                    idx += 1;
                }
                // A trailing elision (e.g. `[1,,]` ⇒ length 2 with a hole at index 1) sets the length
                // past the last defined slot; `arraySet` only bumps length up to the last write.
                if (idx > arr.arrayLen()) try arr.arraySetLen(idx);
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
                // §27.6.3.8 in an ASYNC generator, `yield` is AsyncGeneratorYield (await the operand,
                // then suspend producing {value,done:false}); `yield*` delegates over an async iterator.
                const cg = self.current_gen.?;
                if (cg.is_async_gen) {
                    if (y.delegate) return self.doAsyncYieldDelegate(arg);
                    return self.doAsyncYield(arg);
                }
                // §15.5.5 `yield* expr` delegates to the iterator of `expr`; plain `yield expr` performs
                // a single handoff.
                if (y.delegate) return self.doYieldDelegate(arg);
                return self.doYield(arg);
            },
            .await_expr => |operand| {
                // §27.7.5.3 AwaitExpression — evaluate the operand, then suspend the async body via the
                // ping-pong handoff: the awaited value is carried out, the caller registers fulfill/
                // reject reactions on PromiseResolve(value) that resume this body when it settles. Legal
                // only on an async body thread (`current_gen.is_async`); the parser rejects `await`
                // outside async, but guard defensively for a stray top-level await.
                const oc = try self.evalExpr(operand, env);
                if (oc.isAbrupt()) return oc;
                const cg = self.current_gen orelse return self.throwError("SyntaxError", "await outside an async function");
                if (!cg.is_async) return self.throwError("SyntaxError", "await outside an async function");
                return self.doAwait(oc.normal);
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
            .compound_assign => |ca| return self.evalCompoundAssign(ca, env),
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
                        if (!b.initialized) return self.throwError("ReferenceError", name); // §13.4 TDZ on the GetValue
                        const oldc = try self.toNumberV(b.value);
                        if (oldc.isAbrupt()) return oldc;
                        const old = oldc.normal.number;
                        b.value = .{ .number = old + delta };
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .member => |m| {
                        const oc = try self.evalExpr(m.object, env);
                        if (oc.isAbrupt()) return oc;
                        const cur = try self.getProperty(oc.normal, m.name);
                        if (cur.isAbrupt()) return cur;
                        const oldc = try self.toNumberV(cur.normal);
                        if (oldc.isAbrupt()) return oldc;
                        const old = oldc.normal.number;
                        const sc = try self.setProperty(oc.normal, m.name, .{ .number = old + delta });
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .index => |ix| {
                        const oc = try self.evalExpr(ix.object, env);
                        if (oc.isAbrupt()) return oc;
                        const kc = try self.evalExpr(ix.key, env);
                        if (kc.isAbrupt()) return kc;
                        // §6.2.5.5/.6 + §7.1.19: RequireObjectCoercible(base) precedes the SINGLE
                        // ToPropertyKey; the coerced primitive feeds both the read and the write-back.
                        if (oc.normal == .undefined or oc.normal == .null) return self.throwError("TypeError", "Cannot read properties of null or undefined");
                        const keyc = try self.coercePropertyKey(kc.normal);
                        if (keyc.isAbrupt()) return keyc;
                        const cur = try self.getPropertyV(oc.normal, keyc.normal);
                        if (cur.isAbrupt()) return cur;
                        const oldc = try self.toNumberV(cur.normal);
                        if (oldc.isAbrupt()) return oldc;
                        const old = oldc.normal.number;
                        const sc = try self.setPropertyV(oc.normal, keyc.normal, .{ .number = old + delta });
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .private_member => |pm| {
                        // §13.4 `obj.#x++` — brand-checked read, ToNumber, write back.
                        const oc = try self.evalExpr(pm.object, env);
                        if (oc.isAbrupt()) return oc;
                        const cur = try self.getPrivate(oc.normal, pm.name);
                        if (cur.isAbrupt()) return cur;
                        const oldc = try self.toNumberV(cur.normal);
                        if (oldc.isAbrupt()) return oldc;
                        const old = oldc.normal.number;
                        const sc = try self.setPrivate(oc.normal, pm.name, .{ .number = old + delta });
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = .{ .number = if (u.prefix) old + delta else old } };
                    },
                    .super_member => |sm| {
                        // §13.4 `super.x++` — read via the SuperProperty getter, ToNumber, write back.
                        const key = if (sm.key) |kn| blk: {
                            const kc = try self.evalExpr(kn, env);
                            if (kc.isAbrupt()) return kc;
                            break :blk try self.toString(kc.normal);
                        } else sm.name;
                        const cur = try self.getSuperProperty(key);
                        if (cur.isAbrupt()) return cur;
                        const oldc = try self.toNumberV(cur.normal);
                        if (oldc.isAbrupt()) return oldc;
                        const old = oldc.normal.number;
                        const sc = try self.setSuperProperty(key, .{ .number = old + delta });
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
                        const s = try self.toStringCoerceV(c.normal); // §13.2.8.5: ToPrimitive(string)+ToString; throws on a Symbol
                        switch (s) {
                            .abrupt => |a| return a,
                            .string => |str| try buf.appendSlice(self.arena, str),
                        }
                    }
                }
                return .{ .normal = .{ .string = buf.items } };
            },
            .this => {
                // §13.3.7 / §9.3.3 GetThisBinding: reading `this` before `super(...)` in a derived
                // constructor (the TDZ) is a ReferenceError.
                if (self.this_init_cell) |c| if (!c.*) return self.throwError("ReferenceError", "Must call super constructor in derived class before accessing 'this'");
                return .{ .normal = self.this_val };
            },
            // §13.3.12.1 NewTarget — the active function's [[NewTarget]] (the constructor when invoked
            // via `new`/`super(...)`, else `undefined`). Arrows inherit it lexically (saved/restored
            // like `this_val`, never reset on an arrow [[Call]]).
            .new_target => return .{ .normal = self.new_target },
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
            .super_assign => |sa| {
                // §13.3.5/§6.2.5.6 `super.x = v` / `super[k] = v` — evaluate the (computed) key, then
                // the value, then PutValue through the SuperProperty reference (receiver = `this`).
                const key = if (sa.key) |kn| blk: {
                    const kc = try self.evalExpr(kn, env);
                    if (kc.isAbrupt()) return kc;
                    break :blk try self.toString(kc.normal);
                } else sa.name;
                const vc = try self.evalExpr(sa.value, env);
                if (vc.isAbrupt()) return vc;
                return self.setSuperProperty(key, vc.normal);
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

    /// §13.3.5/§6.2.5.6 SuperProperty write — `super.x = v`. The reference's base is the home
    /// object's [[Prototype]] but the receiver is the current `this` (§10.1.9.2): an accessor found
    /// on the super chain has its SETTER invoked with `this` = the receiver; otherwise the value is
    /// written on the RECEIVER (the instance), not the prototype. (A non-writable data property on
    /// the super chain rejecting the write is an M-subset-deferred edge — see spec 060.)
    fn setSuperProperty(self: *Interpreter, key: []const u8, value: Value) EvalError!Completion {
        if (self.home_object) |home| if (home.prototype) |base| {
            if (base.getProp(key)) |loc| switch (loc.pv.payload) {
                .accessor => |a| {
                    const setter = a.set orelse {
                        if (self.strict) return self.throwError("TypeError", "Cannot set property with only a getter");
                        return .{ .normal = value };
                    };
                    const c = try self.callFunction(setter, &.{value}, self.this_val);
                    if (c.isAbrupt()) return c;
                    return .{ .normal = value };
                },
                .data => {},
            };
        };
        // No accessor on the super chain → Set on the receiver (this), per OrdinarySet.
        return self.setProperty(self.this_val, key, value);
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
        // §13.3.7.1 step 1: `this` must be uninitialized — a second `super(...)` in the same derived
        // constructor (BindThisValue on an already-bound `this`) is a ReferenceError.
        if (self.this_init_cell) |c| if (c.*) return self.throwError("ReferenceError", "Super constructor may only be called once");
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
        // §13.3.7.1: `this` is now bound (BindThisValue) — leave the TDZ before field initializers run
        // (a field initializer may reference `this`).
        if (self.this_init_cell) |c| c.* = true;
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
            .super_member => |sm| {
                // §13.15.2 `super.x ||= v` etc. — read via the SuperProperty getter (key once), guard,
                // then write via the SuperProperty setter (receiver = `this`).
                const key = if (sm.key) |kn| blk: {
                    const kc = try self.evalExpr(kn, env);
                    if (kc.isAbrupt()) return kc;
                    break :blk try self.toString(kc.normal);
                } else sm.name;
                const cur = try self.getSuperProperty(key);
                if (cur.isAbrupt()) return cur;
                if (!shouldAssign(la.op, cur.normal)) return cur;
                const rc = try self.evalExpr(la.value, env);
                if (rc.isAbrupt()) return rc;
                return self.setSuperProperty(key, rc.normal);
            },
            else => return self.throwError("SyntaxError", "Invalid assignment target"),
        }
    }

    /// §13.15.2 compound AssignmentExpression `target op= value` (`+= -= *= …`). The reference is
    /// evaluated ONCE (base + key coerced a single time), its current value read, combined with `value`
    /// via the §13.15.3 operator, and written back. Keeping the node intact (rather than the
    /// `target = target op value` desugar) is what makes a side-effecting base/key run exactly once.
    fn evalCompoundAssign(self: *Interpreter, ca: anytype, env: *Environment) EvalError!Completion {
        switch (ca.target.*) {
            .identifier => |name| {
                // §13.15.2: read the current value, evaluate the RHS, combine, then PutValue. With a
                // `with` in scope the reference is re-resolved at write time (matching §9.1.1.2.5: a
                // getter that deletes its own binding makes the strict-mode PutValue a ReferenceError).
                if (self.with_depth > 0) {
                    const cur: Value = switch (self.resolveIdRef(env, name)) {
                        .with_object => |o| blk: {
                            const c = try self.getProperty(.{ .object = o }, name);
                            if (c.isAbrupt()) return c;
                            break :blk c.normal;
                        },
                        .binding => |b| blk: {
                            if (!b.initialized) return self.throwError("ReferenceError", name);
                            break :blk b.value;
                        },
                        .unresolved => return self.throwError("ReferenceError", name),
                    };
                    const rc = try self.evalExpr(ca.value, env);
                    if (rc.isAbrupt()) return rc;
                    const res = try self.applyNumericOrStringOp(ca.op, cur, rc.normal);
                    if (res.isAbrupt()) return res;
                    switch (self.resolveIdRef(env, name)) { // §6.2.5.6 PutValue: re-resolve the reference
                        .with_object => |o| {
                            const sc = try self.setProperty(.{ .object = o }, name, res.normal);
                            if (sc.isAbrupt()) return sc;
                        },
                        .binding => |b| {
                            if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                            b.value = res.normal;
                        },
                        .unresolved => return self.assignUnresolved(name, res.normal),
                    }
                    return res;
                }
                const b = env.lookup(name) orelse return self.throwError("ReferenceError", name);
                if (!b.initialized) return self.throwError("ReferenceError", name); // §13.x TDZ
                const rc = try self.evalExpr(ca.value, env);
                if (rc.isAbrupt()) return rc;
                const res = try self.applyNumericOrStringOp(ca.op, b.value, rc.normal);
                if (res.isAbrupt()) return res;
                if (!b.mutable) return self.throwError("TypeError", "Assignment to constant variable.");
                b.value = res.normal;
                return res;
            },
            .member => |m| {
                const oc = try self.evalExpr(m.object, env); // base evaluated once
                if (oc.isAbrupt()) return oc;
                const cur = try self.getProperty(oc.normal, m.name);
                if (cur.isAbrupt()) return cur;
                const rc = try self.evalExpr(ca.value, env);
                if (rc.isAbrupt()) return rc;
                const res = try self.applyNumericOrStringOp(ca.op, cur.normal, rc.normal);
                if (res.isAbrupt()) return res;
                const sc = try self.setProperty(oc.normal, m.name, res.normal);
                if (sc.isAbrupt()) return sc;
                return res;
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env); // base evaluated once
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env); // key expression evaluated once
                if (kc.isAbrupt()) return kc;
                // §6.2.5.5/.6: RequireObjectCoercible(base) precedes the SINGLE §7.1.19 ToPropertyKey.
                if (oc.normal == .undefined or oc.normal == .null) return self.throwError("TypeError", "Cannot read properties of null or undefined");
                const keyc = try self.coercePropertyKey(kc.normal);
                if (keyc.isAbrupt()) return keyc;
                const cur = try self.getPropertyV(oc.normal, keyc.normal);
                if (cur.isAbrupt()) return cur;
                const rc = try self.evalExpr(ca.value, env);
                if (rc.isAbrupt()) return rc;
                const res = try self.applyNumericOrStringOp(ca.op, cur.normal, rc.normal);
                if (res.isAbrupt()) return res;
                const sc = try self.setPropertyV(oc.normal, keyc.normal, res.normal);
                if (sc.isAbrupt()) return sc;
                return res;
            },
            .private_member => |pm| {
                const oc = try self.evalExpr(pm.object, env);
                if (oc.isAbrupt()) return oc;
                const cur = try self.getPrivate(oc.normal, pm.name);
                if (cur.isAbrupt()) return cur;
                const rc = try self.evalExpr(ca.value, env);
                if (rc.isAbrupt()) return rc;
                const res = try self.applyNumericOrStringOp(ca.op, cur.normal, rc.normal);
                if (res.isAbrupt()) return res;
                return self.setPrivate(oc.normal, pm.name, res.normal);
            },
            .super_member => |sm| {
                // §13.15.2 `super.x += v` — read via the SuperProperty getter (key evaluated once),
                // combine, write via the SuperProperty setter (receiver = `this`).
                const key = if (sm.key) |kn| blk: {
                    const kc = try self.evalExpr(kn, env);
                    if (kc.isAbrupt()) return kc;
                    break :blk try self.toString(kc.normal);
                } else sm.name;
                const cur = try self.getSuperProperty(key);
                if (cur.isAbrupt()) return cur;
                const rc = try self.evalExpr(ca.value, env);
                if (rc.isAbrupt()) return rc;
                const res = try self.applyNumericOrStringOp(ca.op, cur.normal, rc.normal);
                if (res.isAbrupt()) return res;
                return self.setSuperProperty(key, res.normal);
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
    /// Shared by `new C()` and a bound function's [[Construct]] (§10.4.1.2). The instance's [[Prototype]]
    /// derives from `ctor` (i.e. newTarget === ctor); `Reflect.construct` uses `constructNT` for an
    /// explicit newTarget.
    fn construct(self: *Interpreter, ctor: *Object, args: []const Value) EvalError!Completion {
        return self.constructNT(ctor, args, ctor);
    }

    /// §10.2.2 [[Construct]] with an explicit [[NewTarget]] (§28.1.2 Reflect.construct). The instance's
    /// [[Prototype]] is read from `new_target.prototype` (an object, else %Object.prototype% per §10.1.13
    /// OrdinaryCreateFromConstructor), while the BODY still runs `ctor`. `new_target` must be a
    /// constructor (the caller validates IsConstructor).
    pub fn constructNT(self: *Interpreter, ctor: *Object, args: []const Value, new_target: *Object) EvalError!Completion {
        // §15.3: arrow functions have no [[Construct]] — `new (() => {})` is a TypeError.
        if (ctor.call) |fd| {
            if (fd.is_arrow) return self.throwError("TypeError", "value is not a constructor");
        }
        // §20.4.1: the `Symbol` constructor has no [[Construct]] — `new Symbol()` is a TypeError.
        if (ctor.native == .symbol_ctor) return self.throwError("TypeError", "Symbol is not a constructor");
        // §21.2.1: the `BigInt` constructor has no [[Construct]] — `new BigInt()` is a TypeError.
        if (ctor.native == .bigint_ctor) return self.throwError("TypeError", "BigInt is not a constructor");
        // §17 / §10.3: a built-in *method* or *static* (e.g. `String.prototype.concat`, `String.fromCharCode`,
        // `Math.max`) has NO [[Construct]] — only the genuine built-in *constructors* below do. A native
        // with no AST body (`call == null`) that is not one of those throws "not a constructor". Ordinary
        // functions / bound functions / classes have `native == .none` and a `call` body, so they pass.
        if (ctor.call == null and ctor.native != .none) {
            const constructible = switch (ctor.native) {
                .error_ctor, .aggregate_error_ctor, .suppressed_error_ctor, .string_ctor, .object_ctor, .array_ctor, .function_ctor, .number_ctor, .boolean_ctor, .promise_ctor, .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor, .iterator_ctor, .proxy_ctor, .regexp_ctor => true,
                else => false,
            };
            if (!constructible) return self.throwError("TypeError", "value is not a constructor");
        }
        // §10.1.13 OrdinaryCreateFromConstructor: the instance proto is `new_target.prototype` if an
        // object, else the realm's %Object.prototype% intrinsic (matched here by leaving it null when
        // `new_target.prototype` is absent — Object.create(null) then inherits nothing, but a non-object
        // `.prototype` falls back to %Object.prototype%). For `new C()` new_target === ctor.
        var proto: ?*Object = self.objectProto();
        if (new_target.get("prototype")) |pv| {
            if (pv == .object) proto = pv.object;
        }
        const new_obj = try Object.create(self.arena, proto);

        // §24.1.1.1/§24.2.1.1/§24.3.1.1/§24.4.1.1: a keyed-collection constructor attaches its backing
        // store to the freshly-created instance (which already has new_target.prototype → subclassing
        // works), then AddEntriesFromIterable. The instance IS the result (no explicit-return override).
        switch (ctor.native) {
            .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor => {
                const ic = try self.initCollectionInstance(ctor.native, new_obj, args);
                if (ic.isAbrupt()) return ic;
                return .{ .normal = .{ .object = new_obj } };
            },
            .proxy_ctor => return builtin_proxy.construct(self, new_obj, args), // §28.2.1.1
            .regexp_ctor => return builtin_regexp.construct(self, args), // §22.2.4.1 (new RegExp)
            else => {},
        }

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
            if (fd.is_default_ctor) {
                if (fd.super_ctor) |sup| {
                    // §13.3.12: a synthesized default derived constructor forwards the original `new`
                    // target down the implicit `super(...)`. Set the active `new_target` to this ctor so
                    // `runParentCtor` propagates it (mirroring an explicit `super()` from a real body).
                    const saved_nt = self.new_target;
                    self.new_target = .{ .object = ctor };
                    defer self.new_target = saved_nt;
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

        // §13.3.12: a [[Construct]] sets the running body's [[NewTarget]] to the constructor. Handed off
        // to `callFunction` via the one-shot `pending_new_target` slot, which it consumes for this body.
        self.pending_new_target = .{ .object = ctor };
        const result = try self.callFunction(ctor, args, .{ .object = new_obj });
        if (result.isAbrupt()) return result;
        // §21.1.4.1/§22.1.4.1/§20.3.4.1: a primitive-wrapper ctor (and Array, M75) boxes its internal
        // slot directly on `new_obj` and returns it (`wrapperResult`), so the explicit-object-return
        // path below carries it back. A ctor whose body returns undefined falls through to `new_obj`.
        if (result.normal == .object) return .{ .normal = result.normal }; // explicit object return wins
        return .{ .normal = .{ .object = new_obj } };
    }

    /// §20.3/§21.1/§22.1 primitive-wrapper constructor result: invoked as a constructor
    /// (`new`/`super`, so `native_new_target` is defined) with an object receiver, box `prim` on the
    /// instance's primitive slot ([[BooleanData]]/[[NumberData]]/[[StringData]]) and return the
    /// instance — so subclassing works and the wrapper's prototype methods recover the value. A plain
    /// call (no new_target) returns the primitive.
    fn wrapperResult(self: *Interpreter, prim: Value, this_val: Value) Completion {
        if (self.native_new_target != .undefined and this_val == .object) {
            this_val.object.primitive = prim;
            return .{ .normal = this_val };
        }
        return .{ .normal = prim };
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
        // §13.3.12: `new.target` propagates DOWN a `super(...)` chain unchanged — the parent constructor
        // sees the SAME [[NewTarget]] as the derived class that invoked it (the original `new` target).
        // The active `new_target` is that value (set when this derived ctor body / construct began).
        // A `super(...)` is ALWAYS a [[Construct]], so signal that to `callFunction` (whose §15.7.14
        // class-ctor [[Call]] guard keys on a non-undefined hand-off) even in the edge where the active
        // new_target was lost — e.g. an arrow `() => super()` invoked from an iterator-return handler
        // after the derived ctor body already left (the parent ctor `sup` is itself the fallback marker).
        self.pending_new_target = if (self.new_target == .undefined) .{ .object = sup } else self.new_target;
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
                // §15.7.10 / §8.4 NamedEvaluation: a field with an anonymous function/class initializer
                // gets the field name (string key, or "[desc]" for a symbol-keyed field).
                const fname = if (field.key_symbol) |sym| try self.symbolPropName(sym) else field.key;
                try self.maybeSetAnonName(ie, v, fname);
            }
            if (field.key_symbol) |sym| try instance.setSymbol(sym, v) else try instance.set(field.key, v);
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
                    // §13.2.5.6 / §13.3.5: an object-literal accessor is a MethodDefinition with a
                    // [[HomeObject]] = the object literal, so `super.x` inside it resolves against
                    // `obj.[[Prototype]]`. Set it here (class accessors get theirs via MakeMethod).
                    if (f.call) |*afd| afd.home_object = obj;
                    // §13.2.5.6: an accessor's name is "get x" / "set x" (the key with the kind prefix).
                    const name_key = if (key.symbol) |sym| try self.symbolPropName(sym) else key.key;
                    try self.setFunctionName(f, name_key, if (p.kind == .get) "get" else "set");
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
                    // §13.2.5 / §13.3.5: an object-literal METHOD (`{m(){}}`) is a MethodDefinition with a
                    // [[HomeObject]] = the object literal, so `super.x` inside its body resolves against
                    // `obj.[[Prototype]]`. An ordinary value (`{f: function(){}}`, `{x: 1}`) is NOT a
                    // method and keeps no home — gate on the AST `function` node's `is_method` flag.
                    if (p.value.* == .function and p.value.function.is_method and c.normal == .object) {
                        if (c.normal.object.call) |*mfd| mfd.home_object = obj;
                    }
                    // §B.3.1 `__proto__` Property Names in Object Initializers: a `{__proto__: v}`
                    // colon property (literal, non-computed name) sets [[Prototype]] instead of
                    // creating an own property — if `v` is an Object (set proto to it) or null (null
                    // proto). Any other value (primitive) is IGNORED: no own `__proto__` property and
                    // the prototype is unchanged.
                    if (p.is_proto) {
                        switch (c.normal) {
                            .object => |o| obj.prototype = o,
                            .null => obj.prototype = null,
                            else => {}, // primitive → ignored
                        }
                        continue;
                    }
                    // §13.2.5 PropertyDefinitionEvaluation / §8.4 NamedEvaluation: an object-literal
                    // method (`{m(){}}`, normalized to an anonymous `function` value) OR an anonymous
                    // function/class property value (`{f: function(){}}`) gets the property key as its
                    // name. Object-literal members stay ENUMERABLE (ordinary properties) — only the
                    // function NAME is set, never the enumerability.
                    if (key.symbol) |sym| {
                        try self.maybeSetAnonName(p.value, c.normal, try self.symbolPropName(sym));
                        try obj.setSymbol(sym, c.normal); // §13.2.5 symbol-keyed data property
                    } else {
                        try self.maybeSetAnonName(p.value, c.normal, key.key);
                        try obj.set(key.key, c.normal);
                    }
                },
            }
        }
        return .{ .normal = .{ .object = obj } };
    }

    pub const KeyResult = struct {
        key: []const u8 = "",
        /// Non-null when a computed `[expr]` key evaluated to a Symbol (§13.2.5 ComputedPropertyName +
        /// §7.1.19 ToPropertyKey) — the property is symbol-keyed, not string-keyed.
        symbol: ?*Symbol = null,
        completion: Completion = .{ .normal = .undefined },
        pub fn isAbrupt(self: KeyResult) bool {
            return self.completion.isAbrupt();
        }
    };

    /// Resolve a PropertyDefinition's key: a computed `[expr]` (evaluated → §7.1.19 ToPropertyKey: a
    /// Symbol stays a Symbol, else ToString) or the static identifier/string/numeric key parsed earlier.
    fn propKey(self: *Interpreter, p: ast.Property, env: *Environment) EvalError!KeyResult {
        if (p.computed_key) |ck| {
            const c = try self.evalExpr(ck, env);
            if (c.isAbrupt()) return .{ .completion = c };
            return self.toPropertyKey(c.normal);
        }
        return .{ .key = p.key };
    }

    /// §7.1.19 ToPropertyKey ( argument ) — a Symbol stays a Symbol; an object is ToPrimitive(string)'d
    /// (which may itself yield a Symbol), then any non-symbol primitive is ToString'd. So a computed
    /// `[fn]` key uses the function's `toString` (consistent with `String(fn)`), not a raw fallback.
    pub fn toPropertyKey(self: *Interpreter, v: Value) EvalError!KeyResult {
        if (v == .symbol) return .{ .symbol = v.symbol }; // §7.1.19 step 2
        if (v == .object) {
            const pc = try self.toPrimitive(v, .string);
            if (pc.isAbrupt()) return .{ .completion = pc };
            if (pc.normal == .symbol) return .{ .symbol = pc.normal.symbol };
            return .{ .key = try self.toString(pc.normal) };
        }
        return .{ .key = try self.toString(v) };
    }

    /// §15.7.14 resolve a ClassElement's PropertyName: a computed `[expr]` (evaluated in the class
    /// scope at definition time, ToPropertyKey → ToString in the M-subset) or the static key parsed
    /// earlier. Mirrors `propKey` for object-literal members.
    fn classElementKey(self: *Interpreter, el: ast.ClassElement, env: *Environment) EvalError!KeyResult {
        if (el.computed_key) |ck| {
            const c = try self.evalExpr(ck, env);
            if (c.isAbrupt()) return .{ .completion = c };
            return self.toPropertyKey(c.normal); // §7.1.19 ToPropertyKey (Symbol stays; object → ToPrimitive)
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
        // §15.7.14 step 4: CreateImmutableBinding(className) as UNINITIALIZED (TDZ) BEFORE evaluating
        // the heritage, so a self-reference in `extends` (`class x extends x {}`) is a ReferenceError.
        // Re-declared as the initialized class object after the constructor is built (below).
        if (c.name) |name| try class_env.declare(name, .undefined, false, false);

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
                    // §15.7.14: protoParent = Get(superclass, "prototype"); it must be an Object or
                    // null — a present primitive (number/string/undefined/…) is a TypeError. An object
                    // links the derived prototype; null links to null (no parent prototype).
                    if (so.get("prototype")) |pv| switch (pv) {
                        .object => |po| super_proto = po,
                        .null => {},
                        else => return self.throwError("TypeError", "Class extends value does not have a valid prototype property"),
                    };
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
            .is_default_ctor = ctor_fn == null, // no explicit `constructor` → synthesized default
            .super_ctor = super_ctor,
            .strict = true, // §15.7: a class body (and thus its constructor) is always strict
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
        // §15.7.14: the `constructor` own property of `.prototype` is non-enumerable (writable +
        // configurable). `set` would make it enumerable, so define it explicitly.
        try proto.defineData("constructor", .{ .object = ctor }, true, false, true);
        // §20.2.4.1/.2: the constructor's `length` = ExpectedArgumentCount of its params; its `name`
        // is the class name (or "" for an anonymous class expression — a NamedEvaluation site may
        // rename it). §15.7.14 step 17/18 SetFunctionName/SetFunctionLength on the constructor.
        try setFunctionLength(ctor, paramCount(ctor.call.?.params));
        try self.setFunctionName(ctor, c.name orelse "", "");

        // §15.7.14 link the prototype chains for inheritance.
        if (is_derived) {
            // `proto.[[Prototype]]` = `Super.prototype` (or null for `extends null` / a parent whose
            // `.prototype` is not an object).
            proto.prototype = if (super_proto_is_null) null else super_proto;
            // `ctor.[[Prototype]]` = `Super` (static inheritance). For `extends null` there is no
            // parent constructor, so static inheritance falls back to the default function proto chain.
            ctor.prototype = super_ctor;
        } else {
            // §15.7.14 step 6.a: a base class (no `extends`) has `protoParent` = %Object.prototype%, so
            // `C.prototype.[[Prototype]]` is `Object.prototype` (the freshly-created proto object that
            // `createFunction` made has a null [[Prototype]] — relink it here).
            proto.prototype = self.objectProto();
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
                    block_env.is_var_scope = true; // §15.7.11: a ClassStaticBlock is its own VariableEnvironment
                    try self.hoistVarNames(el.value.block, block_env);
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
                        // §15.7.14: a private method's name is `#m` (its key includes the `#`).
                        try self.setFunctionName(f, el.key, "");
                        if (el.is_static) {
                            try ctor.setPrivate(el.key, fc.normal);
                        } else {
                            try private_elements.append(self.arena, .{ .key = el.key, .kind = .method, .func = f });
                        }
                    } else {
                        const key = try self.classElementKey(el, class_env);
                        if (key.isAbrupt()) return key.completion;
                        // §15.7.14: a class method's `name` is its property key (symbol → "[desc]").
                        try self.setFunctionName(f, if (key.symbol) |sym| try self.symbolPropName(sym) else key.key, "");
                        // §15.7.x: class methods are NON-enumerable (writable + configurable). Define
                        // explicitly (vs `set`, which would make it enumerable like an object method).
                        if (key.symbol) |sym| {
                            try target.defineSymbolData(sym, fc.normal, true, false, true);
                        } else {
                            try target.defineData(key.key, fc.normal, true, false, true);
                        }
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
                        // §15.7.14: a private accessor's name is "get #x" / "set #x".
                        try self.setFunctionName(f, el.key, if (el.kind == .get) "get" else "set");
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
                        // §15.7.14: a class accessor's name is "get x" / "set x" (symbol → "[desc]").
                        try self.setFunctionName(f, if (key.symbol) |sym| try self.symbolPropName(sym) else key.key, if (el.kind == .get) "get" else "set");
                        const getter: ?*Object = if (el.kind == .get) f else null;
                        const setter: ?*Object = if (el.kind == .set) f else null;
                        // §15.7.x: class accessors are NON-enumerable (configurable). Define explicitly.
                        if (key.symbol) |sym| {
                            try target.defineSymbolAccessorEx(sym, getter, setter, false);
                        } else {
                            try target.defineAccessorEx(key.key, getter, setter, false);
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
                    // §15.7.10: a field's name (string key, or "[desc]" for a symbol key) is the
                    // NamedEvaluation name for an anonymous function/class initializer.
                    const field_name = if (key.symbol) |sym| try self.symbolPropName(sym) else key.key;
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
                            try self.maybeSetAnonName(ie, v, field_name); // §8.4 NamedEvaluation
                        }
                        if (key.symbol) |sym| try ctor.setSymbol(sym, v) else try ctor.set(key.key, v);
                    } else {
                        // §15.7.14: the instance FieldDefinition's name is evaluated now (definition
                        // order); the initializer is run per-instance by initInstanceFields.
                        try fields.append(self.arena, .{ .key = key.key, .init = el.value.field_init, .key_symbol = key.symbol });
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

    /// §15.1.5 ExpectedArgumentCount — the `length` value: the count of leading FormalParameters
    /// before the first one with a default initializer, a destructuring BindingPattern, or the rest
    /// element. (A simple identifier param with no default counts; the first non-simple param or the
    /// rest element stops the count.) `rest` is never counted (only stops the leading run).
    fn paramCount(params: []const ast.Param) f64 {
        var n: f64 = 0;
        for (params) |p| {
            if (p.default != null or p.pattern.* != .identifier) break;
            n += 1;
        }
        return n;
    }

    /// §20.2.4.1 install the `length` own data property — `{ writable:false, enumerable:false,
    /// configurable:true }`. Created at function-object creation (outside hot loops, so the two
    /// inserts cost nothing in the bench).
    fn setFunctionLength(obj: *Object, n: f64) std.mem.Allocator.Error!void {
        try obj.defineData("length", .{ .number = n }, false, false, true);
    }

    /// §10.2.4 MakeConstructor — install the `constructor` back-reference on an ordinary function's
    /// own `.prototype`: `F.prototype.constructor === F`, descriptor `{ writable:true,
    /// enumerable:false, configurable:true }`. So `function F(){}; F.prototype.constructor === F`
    /// and (through the chain) `new F().constructor === F`. NON-enumerable is load-bearing (a stray
    /// enumerable `constructor` would surface in for-in / Object.keys). Only ordinary (constructible)
    /// functions are MakeConstructor targets: arrows have no `.prototype`; a Generator/AsyncGenerator
    /// function's `.prototype` is the (non-constructor) %Generator%-instance prototype and carries no
    /// `constructor` (§27.x.4); an async function has no own `.prototype`. Runs at function-object
    /// creation (outside hot loops).
    fn setConstructorBackref(obj: *Object) std.mem.Allocator.Error!void {
        const fd = obj.call orelse return;
        // Not a MakeConstructor target: arrows, generators/async-generators, async functions, and
        // §10.2.5 MethodDefinitions (which have no own `.prototype` to hang a `constructor` on).
        if (fd.is_arrow or fd.is_generator or fd.is_async or fd.is_method) return;
        const pv = obj.get("prototype") orelse return;
        if (pv != .object) return;
        try pv.object.defineData("constructor", .{ .object = obj }, true, false, true);
    }

    /// §20.2.4.2 / §10.2.9 SetFunctionName — install the `name` own data property `{ writable:false,
    /// enumerable:false, configurable:true }`. `prefix` (when non-empty) is space-joined ahead of the
    /// name ("get"/"set"/"bound"). Names are interned in the realm arena so they outlive the call.
    fn setFunctionName(self: *Interpreter, obj: *Object, name: []const u8, prefix: []const u8) std.mem.Allocator.Error!void {
        const full = if (prefix.len == 0) name else try std.fmt.allocPrint(self.arena, "{s} {s}", .{ prefix, name });
        try obj.defineData("name", .{ .string = full }, false, false, true);
    }

    /// §10.2.9 SetFunctionName for a Symbol key — the name is `"[" + description + "]"`, or `""` when
    /// the symbol has no description (`[[Description]]` is undefined). Interned in the realm arena.
    fn symbolPropName(self: *Interpreter, sym: *Symbol) std.mem.Allocator.Error![]const u8 {
        const desc = sym.description orelse return "";
        return std.fmt.allocPrint(self.arena, "[{s}]", .{desc});
    }

    /// True iff a function object currently has no `name` own property, or an empty-string one — i.e.
    /// it is "anonymous" and eligible for §8.4 NamedEvaluation to assign it a binding/property name.
    fn isAnonymousFn(obj: *Object) bool {
        if (obj.properties.getPtr("name")) |pv| {
            return pv.payload == .data and pv.payload.data == .string and pv.payload.data.string.len == 0;
        }
        return true;
    }

    /// §8.4 NamedEvaluation — if `node` is an anonymous function/arrow/class expression and the
    /// evaluated `value` is the resulting (still-anonymous) function object, set its `name` to the
    /// binding/property name. Covers the common naming contexts: `var/let/const f = <anon>`,
    /// `f = <anon>` (identifier assignment), object-literal `{f: <anon>}`, and default initializers.
    /// A no-op for any non-anonymous-function value, so callers can apply it unconditionally.
    fn maybeSetAnonName(self: *Interpreter, node: *const ast.Node, value: Value, name: []const u8) std.mem.Allocator.Error!void {
        switch (node.*) {
            .function, .class_expr => {},
            else => return, // only an anonymous function/class literal is a NamedEvaluation site
        }
        if (value != .object) return;
        const obj = value.object;
        if (obj.kind != .function) return;
        if (!isAnonymousFn(obj)) return; // a NAMED function/class expression keeps its own name
        try self.setFunctionName(obj, name, "");
    }

    fn evalFunctionExpr(self: *Interpreter, f: *const ast.Function, env: *Environment) EvalError!Completion {
        // §15.2.5 InstantiateOrdinaryFunctionExpression: a NAMED FunctionExpression `function g(){…}`
        // binds its own name `g` in an inner DeclarativeEnvironment that is the function's [[Environment]]
        // — so the body (and parameter defaults) can self-reference / recurse via `g`, while `g` is NOT
        // visible in the enclosing scope. The binding is immutable. Arrows have no name; a method's name
        // is not a self-binding either — both use the outer `env` directly.
        const has_self_name = f.name != null and !f.is_arrow and !f.is_method;
        const closure_env = if (has_self_name) try Environment.create(self.arena, env) else env;
        // §15.3: an arrow captures the enclosing `this` at creation time (lexical `this`); an
        // ordinary function gets `this` bound per-call instead.
        const obj = try Object.createFunction(self.arena, .{
            .params = f.params,
            .rest = f.rest,
            .body = f.body,
            .closure = closure_env,
            .is_arrow = f.is_arrow,
            .is_generator = f.is_generator,
            .is_async = f.is_async,
            .is_method = f.is_method,
            .captured_this = if (f.is_arrow) self.this_val else .undefined,
            .captured_this_init_cell = if (f.is_arrow) self.this_init_cell else null, // §13.3.7 lexical TDZ
            .captured_home_object = if (f.is_arrow) self.home_object else null, // §13.3.5 lexical [[HomeObject]]
            .strict = f.strict,
        });
        obj.prototype = self.functionProto(); // §20.2.3 so `f.call`/`.apply`/`.bind` resolve
        // §20.2.4.1/.2: install `length` (ExpectedArgumentCount) and `name` (the declared name, or
        // "" for an anonymous expression — a NamedEvaluation site may rename it via maybeSetAnonName).
        try setFunctionLength(obj, paramCount(f.params));
        try self.setFunctionName(obj, f.name orelse "", "");
        try setConstructorBackref(obj); // §10.2.4 MakeConstructor: F.prototype.constructor === F (no-op for arrows)
        // §15.2.5 step 4: initialize the immutable self-name binding to the created function object.
        if (has_self_name) try closure_env.declare(f.name.?, .{ .object = obj }, false, true);
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
        // §19.2.1.1 / §13.3.6: a DIRECT eval is a CallExpression whose callee is *exactly* the
        // IdentifierReference `eval` resolving to the %eval% intrinsic. Detect it here (before the
        // generic dispatch) so the eval body runs in the CALLER's running execution context.
        var is_direct_eval = false;
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
                // §19.2.1.1: the callee is the bare IdentifierReference `eval`, and it resolved to the
                // %eval% intrinsic (NOT a shadowing user binding named `eval`). This is a DIRECT eval.
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval")) {
                    if (cc.normal == .object and cc.normal.object.native == .eval_fn) is_direct_eval = true;
                }
            },
        }

        var args: std.ArrayListUnmanaged(Value) = .empty;
        const alc = try self.evalSpreadList(c.args, env, &args);
        if (alc.isAbrupt()) return alc;

        // §19.2.1.1 DIRECT eval: run in the CALLER's running execution context. A non-string argument
        // is returned unchanged (§19.2.1 step 2). Otherwise the eval body runs in a fresh CHILD of the
        // caller's current `env` — reads/writes of surrounding bindings work, and `let`/`const`/`class`
        // (and, in this slice, `var`) declared by the eval are eval-local. `this_val`/`home_object` are
        // inherited (left at the interpreter's current values). Counters carry through.
        if (is_direct_eval) {
            const arg: Value = if (args.items.len > 0) args.items[0] else .undefined;
            if (arg != .string) return .{ .normal = arg };
            const eval_env = try Environment.create(self.arena, env);
            // §19.2.1.1: a DIRECT eval inherits the caller's strictness. (Whether the eval scope is a
            // VariableEnvironment depends on the eval body's OWN strictness — set in `performEval`.)
            return self.performEval(arg.string, eval_env, self.strict);
        }

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
    /// The global object as a Value (the realm's `%GlobalThis%`), or null in a realm-less context.
    /// Used for §10.2.1.2 sloppy `this` substitution and §9.4.2 global `this`.
    fn globalThisValue(self: *Interpreter) ?Value {
        if (self.globals) |g| if (g.lookup("%GlobalThis%")) |b| return b.value;
        return null;
    }

    /// §10.4.4.6 the realm's unique %ThrowTypeError% intrinsic, or null in a realm-less context.
    fn throwTypeErrorIntrinsic(self: *Interpreter) ?*Object {
        if (self.globals) |g| if (g.lookup("%ThrowTypeError%")) |b| if (b.value == .object) return b.value.object;
        return null;
    }

    pub fn callFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        // §13.3.12: consume the one-shot [[NewTarget]] hand-off from a preceding `construct` (else
        // `undefined`) and clear the slot immediately — so it cannot leak past this [[Call]] into a
        // sibling/native/bound/generator dispatch. Installed below for the non-arrow ordinary body path.
        const pending_new_target = self.pending_new_target;
        self.pending_new_target = .undefined;
        // §15.7.14: a class constructor's [[Call]] always throws — only [[Construct]] (a preceding
        // `construct` that handed off [[NewTarget]] via `pending_new_target`) runs its body. An
        // undefined hand-off ⇒ this is a plain [[Call]] (direct OR via call/apply/bind), so reject it
        // here at the single [[Call]] chokepoint. A bound wrapper has `func.call == null`, so the
        // check no-ops on it and fires on the unwrapped target's recursive call.
        if (pending_new_target == .undefined) {
            if (func.call) |cfd| if (cfd.is_class_ctor)
                return self.throwError("TypeError", "Class constructor cannot be invoked without 'new'");
        }
        // §10.4.1.1 [[Call]] of a Bound Function Exotic Object: run the target with `this` =
        // [[BoundThis]] and args = [[BoundArguments]] ++ callArgs. Cheap early branch (the common
        // case is `.bound == null`, a single optional test off the hot path).
        if (func.bound) |b| {
            const merged = try self.concatArgs(b.bound_args, args);
            return self.callFunction(b.target, merged, b.bound_this);
        }
        if (func.native != .none) {
            // Expose THIS call's [[NewTarget]] to the native — a built-in constructor reached via a
            // `super(...)` chain (defined → construct) must initialize the instance, while a plain call
            // (undefined) throws "requires 'new'". Reset by every dispatch so it never leaks.
            self.native_new_target = pending_new_target;
            return self.callNative(func, args, this_val);
        }
        // §15.5.4 / §27.5: calling a generator function does NOT run the body — it returns a fresh
        // Generator object in `suspended_start` (the body runs on its own thread later, on `.next`).
        // Checked before the depth bump so it pays no recursion budget; ordinary functions skip it.
        if (func.call) |fd0| {
            // §10.2.1.2 OrdinaryCallBindThis: generator / async functions snapshot `this` here (off the
            // ordinary-body path below), so apply the non-strict global-`this` substitution before they
            // capture it — otherwise a sloppy `function* g(){}` / `async function f(){}` called with
            // undefined `this` would see undefined instead of the global object. Arrows: captured_this.
            const gen_this = if (!fd0.is_arrow and !fd0.strict and (this_val == .undefined or this_val == .null))
                (self.globalThisValue() orelse this_val)
            else
                this_val;
            // §27.6.2 an async generator (`async function*`) [[Call]] returns an AsyncGenerator object
            // (lazy — the body runs on its own thread when first driven). Checked before the plain
            // generator / async branches (it is both is_async AND is_generator).
            if (fd0.is_generator and fd0.is_async) return self.createAsyncGenerator(func, args, gen_this);
            if (fd0.is_generator) return self.createGenerator(func, args, gen_this);
            // §27.7.5.1 an async function's [[Call]] returns a Promise immediately and runs the body on
            // a generator-style thread, suspending at each `await`.
            if (fd0.is_async) return self.callAsyncFunction(func, args, gen_this);
        }
        // Each call stacks several heavy native frames — count call depth too so the guard
        // fires before the native stack overflows (these frames are bigger than expr frames).
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > self.max_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
        const fd = func.call orelse return self.throwError("TypeError", "value is not a function");
        const call_env = try Environment.create(self.arena, fd.closure);
        call_env.is_var_scope = true; // §10.2.11: a FunctionBody is a VariableEnvironment (var hoist target)
        // §10.2.11 FunctionDeclarationInstantiation: the `this` / [[HomeObject]] / [[NewTarget]] bindings
        // are established BEFORE parameter initialization, so a default-parameter initializer (`m(x =
        // super.k)`, `f(p = this.q)`, `C(t = new.target)`) sees the correct method context. Installed
        // here (ahead of the param loop), saved/restored on return.
        // §15.3: an arrow has no own `this` binding — it uses the `this` captured at creation,
        // ignoring however it was called. Ordinary functions take the call-site `this`.
        const saved_this = self.this_val;
        self.this_val = if (fd.is_arrow) fd.captured_this else blk: {
            // §10.2.1.2 OrdinaryCallBindThis (this-mode = global): a NON-STRICT ordinary function called
            // with a `this` of undefined/null uses the global object instead. Strict functions keep the
            // value as-is; arrows use their captured `this`. (Primitive-`this` boxing in sloppy mode is a
            // separate refinement, not handled here.)
            if (!fd.strict and (this_val == .undefined or this_val == .null)) break :blk (self.globalThisValue() orelse this_val);
            break :blk this_val;
        };
        defer self.this_val = saved_this;
        // §13.3.7 [[ThisBindingStatus]]: select the active `this`-binding init cell. An ARROW restores
        // the cell it captured at creation (its lexical constructor's TDZ state); a DERIVED constructor
        // allocates a fresh cell starting `false` (TDZ until `super()`); every other function has an
        // always-initialized `this` (null cell). Saved/restored so nesting (and an arrow invoked from an
        // unrelated method mid-construction) resolves `this`/`super()` against the correct binding.
        const saved_init_cell = self.this_init_cell;
        if (fd.is_arrow) {
            self.this_init_cell = fd.captured_this_init_cell;
        } else if (fd.is_derived_ctor) {
            const cell = try self.arena.create(bool);
            cell.* = false;
            self.this_init_cell = cell;
        } else {
            self.this_init_cell = null;
        }
        defer self.this_init_cell = saved_init_cell;
        // §9.2.5/§13.3.5: a method invocation installs its [[HomeObject]] for `super` resolution.
        // An arrow has no own home object — it lexically keeps the enclosing one (like `this`), so
        // it is left untouched; an ordinary function's home_object is null, masking outer `super`.
        const saved_home = self.home_object;
        // §13.3.5: an arrow uses the [[HomeObject]] it captured LEXICALLY (so `super` resolves against
        // its defining method/constructor regardless of how the arrow is invoked); an ordinary function
        // installs its own (null for a non-method, masking outer `super`).
        self.home_object = if (fd.is_arrow) fd.captured_home_object else fd.home_object;
        defer self.home_object = saved_home;
        // §13.3.12: install [[NewTarget]] for this body. An ordinary [[Call]] gets `undefined`; a
        // [[Construct]] (`construct` set `pending_new_target` to the constructor right before this call)
        // gets that constructor. An arrow has no own [[NewTarget]] — it keeps the enclosing one lexically
        // (like `this`), so it is left untouched. The pending slot was consumed at the top of this
        // [[Call]] so nested ordinary calls within the body see `undefined`.
        const saved_new_target = self.new_target;
        if (!fd.is_arrow) self.new_target = pending_new_target;
        defer self.new_target = saved_new_target;
        for (fd.params, 0..) |param, i| {
            var v: Value = if (i < args.len) args[i] else .undefined; // missing args → undefined
            var defaulted = false;
            if (v == .undefined) {
                if (param.default) |dn| { // §15.1 default value applied when the arg is undefined
                    const dc = try self.evalExpr(dn, call_env);
                    if (dc.isAbrupt()) return dc;
                    v = dc.normal;
                    defaulted = true;
                }
            }
            // Fast path: a plain identifier parameter binds directly (no pattern matching).
            if (param.pattern.* == .identifier) {
                // §15.1.3 step on a SingleNameBinding: name an anonymous fn/class default initializer.
                if (defaulted) try self.maybeSetAnonName(param.default.?, v, param.pattern.identifier);
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
            const ao = try self.makeArgumentsObject(args, func, call_env, fd);
            try call_env.declare("arguments", .{ .object = ao }, true, true);
        }
        // §14.13: labels do not cross a function boundary — the body starts with no pending label
        // (e.g. a call inside a labelled statement must not leak that label into the callee's loops).
        const saved_labels = self.pending_labels;
        self.pending_labels = .empty;
        defer self.pending_labels = saved_labels;
        // §11.2.2: the body runs in its own strict context (`fd.strict`, computed at parse time —
        // inherited strict, an own `"use strict"`, a class member, or a class constructor). Restored on
        // return so the caller's strictness is unaffected. A sloppy callee called from strict code (and
        // vice-versa) is gated correctly for §6.2.5.6 PutValue to an unresolved name.
        const saved_strict = self.strict;
        self.strict = fd.strict;
        defer self.strict = saved_strict;

        // §10.2.11 FunctionDeclarationInstantiation (lexical step): hoist the body's top-level
        // `let`/`const`/`class` names as TDZ bindings before it runs (so a forward reference throws).
        try self.hoistLexicalNames(fd.body, call_env);
        // §10.2.11 (var step): instantiate VarDeclaredNames in the FunctionBody VariableEnvironment,
        // descending through nested blocks/loops/try (no-clobber over params already bound above).
        try self.hoistVarNames(fd.body, call_env);
        // §ER: a FunctionBody lexically containing a `using`/`await using` disposes its resources on
        // exit (normal return OR throw). Gated on `blockHasUsing` so an ordinary body pays nothing.
        if (blockHasUsing(fd.body)) {
            const marker = self.disposables.items.len;
            var body_c: Completion = .{ .normal = .undefined };
            for (fd.body) |stmt| {
                const c = try self.evalStmt(stmt, call_env);
                switch (c) {
                    .normal => {},
                    .ret, .throw => {
                        body_c = c;
                        break;
                    },
                    .brk, .cont => {},
                }
            }
            const disposed = try self.disposeFrom(marker, body_c);
            return switch (disposed) {
                .ret => |v| .{ .normal = v },
                .throw => disposed,
                else => .{ .normal = .undefined },
            };
        }
        for (fd.body) |stmt| {
            const c = try self.evalStmt(stmt, call_env);
            switch (c) {
                .normal => {},
                .ret => |v| return self.finishCtorReturn(fd, v),
                .throw => return c,
                .brk, .cont => {}, // not produced inside a function body (loops/labels consume them)
            }
        }
        return self.finishCtorReturn(fd, .undefined); // implicit return
    }

    /// §10.2.1.3 EvaluateBody (constructor return): a DERIVED constructor that returns `undefined`
    /// (an explicit `return;` or an implicit fall-off) without having called `super(...)` leaves `this`
    /// uninitialized → ReferenceError (GetThisBinding). An object return, or any return after super(),
    /// is unchanged. (Non-derived functions return their value untouched.)
    fn finishCtorReturn(self: *Interpreter, fd: object_mod.FunctionData, value: Value) EvalError!Completion {
        if (fd.is_derived_ctor and value == .undefined) {
            if (self.this_init_cell) |c| if (!c.*)
                return self.throwError("ReferenceError", "Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
        }
        return .{ .normal = value };
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
                // §8.5.2 IteratorBindingInitialization — GetIterator(value) ONCE, then step the iterator
                // exactly once per element (Arrays/Strings fast-pathed). When the pattern is satisfied
                // without a rest element and the iterator is not done, IteratorClose it (§7.4.11). An
                // abrupt completion mid-destructuring also closes a not-done iterator before propagating.
                const opened = try self.destrOpen(value);
                var rec: ArrayDestr = switch (opened) {
                    .abrupt => |c| return c,
                    .driver => |d| d,
                };
                for (ap.elements) |el| {
                    // §8.5.2: each element (incl. an elision) advances the iterator exactly once.
                    const sc = try self.destrStep(&rec);
                    if (sc.isAbrupt()) return sc; // IteratorStep threw → already done, no close needed
                    if (el.target == null) continue; // elision / hole — value consumed, bound nowhere
                    var v: Value = sc.normal;
                    if (v == .undefined) {
                        if (el.default) |dn| { // §8.6.2 apply the `= default` when undefined
                            const dc = self.evalExpr(dn, env) catch |e| {
                                try self.destrClose(rec); // engine error mid-pattern → close, then propagate
                                return e;
                            };
                            if (dc.isAbrupt()) {
                                try self.destrClose(rec); // §8.5.2: abrupt default closes a not-done iterator
                                return dc;
                            }
                            v = dc.normal;
                            // §8.6.2 SingleNameBinding step 6.d: an anonymous fn/class default initializer
                            // bound to a single identifier takes that identifier as its `name`.
                            if (el.target.?.* == .identifier)
                                try self.maybeSetAnonName(dn, v, el.target.?.identifier);
                        }
                    }
                    const bc = self.bindPattern(el.target.?, v, env, mutable) catch |e| {
                        try self.destrClose(rec);
                        return e;
                    };
                    if (bc.isAbrupt()) {
                        try self.destrClose(rec); // §8.5.2: a throwing sub-pattern closes the iterator
                        return bc;
                    }
                }
                if (ap.rest) |rest_pat| {
                    // §13.15.5.3 BindingRestElement — drain the REMAINDER into a fresh Array (consumes to
                    // completion; step-bounded so an infinite iterable fails via the watchdog).
                    const rest = try self.destrRest(&rec);
                    const rest_arr = switch (rest) {
                        .abrupt => |c| return c, // a throwing next() during the drain (iterator now done)
                        .array => |a| a,
                    };
                    const bc = try self.bindPattern(rest_pat, .{ .object = rest_arr }, env, mutable);
                    if (bc.isAbrupt()) return bc;
                } else {
                    // §13.15.5.3: pattern satisfied with no rest → close the iterator if not done. A
                    // NORMAL completion close (§7.4.11): a throwing `return()` / non-object propagates.
                    const cc = try self.destrCloseChecked(rec);
                    if (cc.isAbrupt()) return cc;
                }
                return .{ .normal = .undefined };
            },
            .object => |op| {
                // §13.15.5.5 ObjectBindingPattern — requires a coercible value (§13.15.5.4).
                if (value == .undefined or value == .null) {
                    return self.throwError("TypeError", "Cannot destructure null or undefined");
                }
                // §14.3.3 with a BindingRestProperty: the set of property keys bound by the explicit
                // properties is excluded from the rest. A ComputedPropertyName is evaluated ONCE (in
                // source order, before its value is read) — record the resolved string key so the rest
                // excludes it too (a symbol-valued computed key never collides with the string rest copy).
                var excluded: std.ArrayList([]const u8) = .empty;
                for (op.properties) |prop| {
                    var key_val: Value = .{ .string = prop.key };
                    if (prop.computed) |ck| {
                        // §13.2.5 ComputedPropertyName + §7.1.19 ToPropertyKey, evaluated at bind time.
                        const kc = try self.evalExpr(ck, env);
                        if (kc.isAbrupt()) return kc;
                        key_val = if (kc.normal == .symbol) kc.normal else .{ .string = try self.toString(kc.normal) };
                    }
                    if (op.rest != null and key_val == .string) try excluded.append(self.arena, key_val.string);
                    const gc = try self.getPropertyV(value, key_val);
                    if (gc.isAbrupt()) return gc;
                    var v = gc.normal;
                    if (v == .undefined) {
                        if (prop.default) |dn| {
                            const dc = try self.evalExpr(dn, env);
                            if (dc.isAbrupt()) return dc;
                            v = dc.normal;
                            // §13.3.3.7 KeyedBindingInitialization step 6.d: name an anonymous fn/class
                            // default initializer after a single-identifier binding target.
                            if (prop.target.* == .identifier)
                                try self.maybeSetAnonName(dn, v, prop.target.identifier);
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
                            for (excluded.items) |ek| {
                                if (std.mem.eql(u8, ek, k)) {
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
                // §13.15.5.3 IteratorDestructuringAssignmentEvaluation — GetIterator(value) ONCE, step
                // once per element (Arrays/Strings fast-pathed). A rest element `...t` drains the
                // remainder; otherwise, when the pattern is satisfied and the iterator is not done, close
                // it (§7.4.11). An abrupt completion mid-pattern closes a not-done iterator first.
                const opened = try self.destrOpen(value);
                var rec: ArrayDestr = switch (opened) {
                    .abrupt => |c| return c,
                    .driver => |d| d,
                };
                for (elems) |el| {
                    if (el.* == .spread) {
                        // §13.15.5.3 AssignmentRestElement — drain the remainder, then assign it (the rest
                        // target — identifier / member / index / nested pattern). No close (iterator drained).
                        const rest = try self.destrRest(&rec);
                        const rest_arr = switch (rest) {
                            .abrupt => |c| return c,
                            .array => |a| a,
                        };
                        const rc = try self.assignTargetNode(el.spread, .{ .object = rest_arr }, env);
                        if (rc.isAbrupt()) return rc;
                        return .{ .normal = .undefined }; // rest is always last — done
                    }
                    // §13.15.5.3: every element (incl. an elision) advances the iterator exactly once.
                    const sc = try self.destrStep(&rec);
                    if (sc.isAbrupt()) return sc; // IteratorStep threw → already done, no close needed
                    if (el.* == .elision) continue; // hole — value consumed, assigned nowhere
                    const tc = self.assignElement(el, sc.normal, env) catch |e| {
                        try self.destrClose(rec);
                        return e;
                    };
                    if (tc.isAbrupt()) {
                        try self.destrClose(rec); // §13.15.5.3: a throwing target/default closes the iterator
                        return tc;
                    }
                }
                // §13.15.5.3: pattern satisfied with no rest → close the iterator if not done. A
                // NORMAL completion close (§7.4.11): a throwing `return()` / non-object propagates.
                const cc = try self.destrCloseChecked(rec);
                if (cc.isAbrupt()) return cc;
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
                            // §13.15.5.5 KeyedDestructuringAssignmentEvaluation: name an anonymous
                            // fn/class default on the shorthand `{x = <anon>}` identifier target.
                            if (p.value.* == .identifier)
                                try self.maybeSetAnonName(dn, v, p.value.identifier);
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
                // §13.15.5.2 step 5.d: when the default was used (source undefined), an anonymous
                // fn/class initializer on a single-identifier target takes that name.
                if (value == .undefined) try self.maybeSetAnonName(a.value, v.normal, a.name);
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
    pub fn getProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.proxy) |pd| return builtin_proxy.get(self, pd, .{ .string = key }, base); // §28.2.5.4 [[Get]]
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(o.arrayLen()) } };
                    if (parseIndex(key)) |i| {
                        return .{ .normal = o.arrayGet(i) };
                    }
                    // else fall through to the prototype chain (Array.prototype methods)
                }
                // §22.1.4.1/§10.4.3: a `new String(s)` wrapper is a String exotic — `.length` and the
                // canonical integer indices [0, len) read the boxed [[StringData]] (own, ahead of the
                // ordinary chain) so wrapper.length / wrapper[i] mirror the primitive (M-subset: byte
                // model). A defined own data property still wins (none clobbers these read-only slots).
                if (o.primitive != null and o.primitive.? == .string and o.getProp(key) == null) {
                    const sv = o.primitive.?.string;
                    if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(sv.len) } };
                    if (parseIndex(key)) |i| {
                        if (i < sv.len) return .{ .normal = .{ .string = sv[i .. i + 1] } };
                    }
                }
                // §10.4.4.3: a MAPPED arguments index reads the LIVE parameter binding (the map takes
                // precedence over the stored value, which may be stale after the parameter was reassigned).
                if (o.mapped_params) |mp| {
                    if (parseIndex(key)) |i| {
                        if (i < mp.names.len and mp.names[i].len > 0) {
                            if (mp.env.lookupLocal(mp.names[i])) |b| return .{ .normal = b.value };
                        }
                    }
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
            .bigint => {
                // §6.1.6.2: transparent boxing — `(1n).toString` / `valueOf` / `constructor` resolve on
                // BigInt.prototype. (Accessors on the proto get `this` = the original primitive base.)
                if (self.globalProto("BigInt")) |proto| {
                    const loc = proto.getProp(key) orelse return .{ .normal = .undefined };
                    switch (loc.pv.payload) {
                        .data => |dv| return .{ .normal = dv },
                        .accessor => |a| {
                            const getter = a.get orelse return .{ .normal = .undefined };
                            return self.callFunction(getter, &.{}, base);
                        },
                    }
                }
                return .{ .normal = .undefined };
            },
            .number => {
                // §21.1.3: transparent boxing — `(255).toString` / `valueOf` / `toFixed` / `constructor`
                // resolve on Number.prototype (accessors get `this` = the original primitive base).
                if (self.globalProto("Number")) |proto| {
                    const loc = proto.getProp(key) orelse return .{ .normal = .undefined };
                    switch (loc.pv.payload) {
                        .data => |dv| return .{ .normal = dv },
                        .accessor => |a| {
                            const getter = a.get orelse return .{ .normal = .undefined };
                            return self.callFunction(getter, &.{}, base);
                        },
                    }
                }
                return .{ .normal = .undefined };
            },
            .boolean => {
                // §20.3.3: transparent boxing — `(true).toString` / `valueOf` resolve on Boolean.prototype.
                if (self.globalProto("Boolean")) |proto| {
                    const loc = proto.getProp(key) orelse return .{ .normal = .undefined };
                    switch (loc.pv.payload) {
                        .data => |dv| return .{ .normal = dv },
                        .accessor => |a| {
                            const getter = a.get orelse return .{ .normal = .undefined };
                            return self.callFunction(getter, &.{}, base);
                        },
                    }
                }
                return .{ .normal = .undefined };
            },
            .undefined, .null => return self.throwError("TypeError", "Cannot read properties of null or undefined"),
        }
    }

    pub fn stringProto(self: *Interpreter) ?*Object {
        return self.globalProto("String");
    }

    /// §10.1.9 [[Set]]. Setting on null/undefined throws; on other primitives is a no-op in M1.
    /// Public wrapper over `setProperty` for the built-in method files (e.g. Array.from/of setting
    /// `length` on a non-Array constructor result via §7.3.4 Set).
    pub fn setPropertyPub(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
        return self.setProperty(base, key, value);
    }

    pub fn setProperty(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.kind == .array) {
                    if (std.mem.eql(u8, key, "length")) {
                        // §23.1.4.1 ArraySetLength — ToUint32; a non-integral / >2^32-1 value is a
                        // RangeError. No eager fill on a length increase (sparse): just record it.
                        const n = toNumber(value);
                        if (std.math.isNan(n) or n < 0 or n > 4294967295.0 or n != @floor(n)) {
                            return self.throwError("RangeError", "Invalid array length");
                        }
                        const new_len: usize = @intFromFloat(n);
                        // §10.4.2.4: a non-writable `length` (frozen array, or an explicit
                        // defineProperty making it non-writable) rejects a CHANGE — TypeError in strict,
                        // silent no-op in sloppy. A no-op assignment to the same value is allowed.
                        if (!o.array_length_writable and new_len != o.arrayLen()) {
                            if (self.strict) return self.throwError("TypeError", "Cannot assign to read only property 'length'");
                            return .{ .normal = value };
                        }
                        try o.arraySetLen(new_len);
                        return .{ .normal = value };
                    }
                    if (parseIndex(key)) |i| {
                        // Hot path: an extensible, non-frozen array takes the raw dense/sparse set.
                        if (o.extensible and !o.array_frozen) {
                            try o.arraySet(o.arena, i, value);
                            return .{ .normal = value };
                        }
                        // §10.1.9.2: a frozen array rejects any element write; a non-extensible array
                        // rejects a NEW index (an existing index of a sealed array stays writable).
                        const reject = o.array_frozen or !o.arrayHas(i);
                        if (reject) {
                            if (self.strict) return self.throwError("TypeError", "Cannot add/modify property on a non-extensible array");
                            return .{ .normal = value };
                        }
                        try o.arraySet(o.arena, i, value);
                        return .{ .normal = value };
                    }
                }
                // §10.1.9.2 OrdinarySetWithOwnDescriptor — if `key` resolves to an accessor on the
                // chain, invoke its setter with `this` = receiver; a getter-only accessor is a silent
                // no-op (sloppy). A data property (own or inherited) → define/overwrite an own data
                // property. The common case (absent or own data) stays a single `set`.
                if (o.getProp(key)) |loc| {
                    if (loc.pv.payload == .accessor) {
                        const setter = loc.pv.payload.accessor.set orelse {
                            // §10.1.9.2: a getter-only accessor (own or inherited) → [[Set]] returns false;
                            // §6.2.5.6 PutValue throws in strict, silent no-op in sloppy.
                            if (self.strict) return self.throwError("TypeError", "Cannot set property that has only a getter");
                            return .{ .normal = value };
                        };
                        const sc = try self.callFunction(setter, &.{value}, base);
                        if (sc.isAbrupt()) return sc;
                        return .{ .normal = value };
                    }
                    // §10.1.9.2: a non-writable data property (own or inherited — an inherited non-writable
                    // data property blocks creating a shadowing own property) → [[Set]] returns false.
                    if (!loc.pv.writable) {
                        if (self.strict) return self.throwError("TypeError", "Cannot assign to read only property");
                        return .{ .normal = value };
                    }
                }
                // §10.4.4.4: writing a MAPPED arguments index also writes the live parameter binding
                // (and vice-versa — keeping `arguments[i]` and the parameter in sync).
                if (o.mapped_params) |mp| {
                    if (parseIndex(key)) |i| {
                        if (i < mp.names.len and mp.names[i].len > 0) {
                            if (mp.env.lookupLocal(mp.names[i])) |b| b.value = value;
                        }
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
        // §6.2.5.5 GetValue: RequireObjectCoercible(base) precedes ToPropertyKey — a null/undefined base
        // throws a TypeError *before* the key is coerced (so a throwing `key.toString` never runs).
        if (base == .undefined or base == .null) return self.throwError("TypeError", "Cannot read properties of null or undefined");
        // §7.1.19 ToPropertyKey: an object key is ToPrimitive(string)'d first (so `o[fn]` uses the
        // function's `toString`, matching `String(fn)`); the result may itself be a Symbol.
        if (key == .object) {
            const pc = try self.toPrimitive(key, .string);
            if (pc.isAbrupt()) return pc;
            if (pc.normal == .symbol) return self.getSymbolProperty(base, pc.normal.symbol);
            return self.getProperty(base, try self.toString(pc.normal));
        }
        return self.getProperty(base, try self.toString(key));
    }

    /// §13.3.3 ToPropertyKey-aware [[Set]] for a computed key (`a[k] = v`). Symbol → symbol store; else
    /// ToString + the ordinary string path.
    fn setPropertyV(self: *Interpreter, base: Value, key: Value, value: Value) EvalError!Completion {
        if (key == .symbol) return self.setSymbolProperty(base, key.symbol, value);
        // §6.2.5.6 PutValue: RequireObjectCoercible(base) precedes ToPropertyKey — a null/undefined base
        // throws a TypeError *before* the key is coerced (so a throwing `key.toString` never runs).
        if (base == .undefined or base == .null) return self.throwError("TypeError", "Cannot set properties of null or undefined");
        // §7.1.19 ToPropertyKey: ToPrimitive(string) an object key first (so `o[fn] = v` keys by the
        // function's `toString`, matching `String(fn)`); the primitive may be a Symbol.
        if (key == .object) {
            const pc = try self.toPrimitive(key, .string);
            if (pc.isAbrupt()) return pc;
            if (pc.normal == .symbol) return self.setSymbolProperty(base, pc.normal.symbol, value);
            return self.setProperty(base, try self.toString(pc.normal), value);
        }
        return self.setProperty(base, try self.toString(key), value);
    }

    /// §7.1.19 ToPropertyKey, returning the coerced key as a primitive Value (a String, or a Symbol
    /// when the key is/ToPrimitive's to a Symbol). Used by read-then-write member operations (compound
    /// assignment, `++`/`--`) so a side-effecting `key.toString` runs EXACTLY ONCE — the resulting
    /// primitive is then passed to both `getPropertyV` and `setPropertyV` (which no-op on a primitive).
    fn coercePropertyKey(self: *Interpreter, key: Value) EvalError!Completion {
        if (key != .object) return .{ .normal = key };
        const pc = try self.toPrimitive(key, .string);
        if (pc.isAbrupt()) return pc;
        if (pc.normal == .symbol) return .{ .normal = pc.normal };
        return .{ .normal = .{ .string = try self.toString(pc.normal) } };
    }

    /// §10.1.8 [[Get]] for a Symbol key — own/inherited symbol property (data or accessor). A primitive
    /// base with no symbol slot yields undefined; null/undefined throws (matching the string path).
    pub fn getSymbolProperty(self: *Interpreter, base: Value, key: *Symbol) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.proxy) |pd| return builtin_proxy.get(self, pd, .{ .symbol = key }, base); // §28.2.5.4 [[Get]]
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

    // ── §7.1.1 ToPrimitive ───────────────────────────────────────────────────

    /// §7.1.1 the conversion hint for ToPrimitive — `default`/`number`/`string` (the spec strings
    /// passed to a `@@toPrimitive` method, and the method-name order for OrdinaryToPrimitive).
    pub const PrimHint = enum {
        default,
        number,
        string,
        fn str(self: PrimHint) []const u8 {
            return switch (self) {
                .default => "default",
                .number => "number",
                .string => "string",
            };
        }
    };

    /// The realm's well-known `Symbol.toPrimitive` identity (held on the `Symbol` constructor).
    /// Null only in a realm-less unit-test eval (no `Symbol`), in which case OrdinaryToPrimitive
    /// (valueOf/toString) is still used.
    fn wellKnownToPrimitive(self: *Interpreter) ?*Symbol {
        const g = self.globals orelse return null;
        const b = g.lookup("Symbol") orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("toPrimitive") orelse return null;
        return if (pv == .symbol) pv.symbol else null;
    }

    /// A well-known Symbol identity (`Symbol.<name>`) held on the `Symbol` constructor. Null only in a
    /// realm-less unit eval (no `Symbol`). Used by the §ER dispose machinery (`dispose`/`asyncDispose`).
    pub fn wellKnownSymbol(self: *Interpreter, name: []const u8) ?*Symbol {
        const g = self.globals orelse return null;
        const b = g.lookup("Symbol") orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get(name) orelse return null;
        return if (pv == .symbol) pv.symbol else null;
    }

    /// §ER AddDisposableResource / CreateDisposableResource / GetDisposeMethod — push the resource
    /// `v` (the initialized `using`/`await using` value) onto the dispose stack. A null/undefined `v`
    /// for a sync `using` is a no-op (no resource pushed). Otherwise `v` must be an Object whose
    /// `[@@dispose]` (sync) — or `[@@asyncDispose]`, falling back to `[@@dispose]` (async) — is a
    /// callable method; a missing or non-callable method is a TypeError. Returns an abrupt completion
    /// on that TypeError (or a throw while reading the method); a normal completion when pushed/skipped.
    fn disposePush(self: *Interpreter, v: Value, is_async: bool) EvalError!Completion {
        // §ER CreateDisposableResource step 1.a: a null/undefined sync-dispose resource is a no-op.
        // (For async-dispose, null/undefined is likewise allowed and disposes to a no-op.)
        if (v == .null or v == .undefined) {
            try self.disposables.append(self.arena, .{ .value = .undefined, .method = null, .is_async = is_async });
            return .{ .normal = .undefined };
        }
        // §ER CreateDisposableResource step 1.b.i: a non-Object resource is a TypeError.
        if (v != .object) return self.throwError("TypeError", "using value is not an object");
        var method: ?*Object = null;
        if (is_async) {
            // §ER GetDisposeMethod (async-dispose): try @@asyncDispose, then fall back to @@dispose.
            if (self.wellKnownSymbol("asyncDispose")) |sym| {
                const mc = try self.getSymbolProperty(v, sym);
                if (mc.isAbrupt()) return mc;
                method = try self.disposeMethodOf(mc.normal);
                if (mc.normal != .undefined and mc.normal != .null and method == null) {
                    return self.throwError("TypeError", "Symbol.asyncDispose is not a function");
                }
            }
            if (method == null) {
                if (self.wellKnownSymbol("dispose")) |sym| {
                    const mc = try self.getSymbolProperty(v, sym);
                    if (mc.isAbrupt()) return mc;
                    method = try self.disposeMethodOf(mc.normal);
                    if (mc.normal != .undefined and mc.normal != .null and method == null) {
                        return self.throwError("TypeError", "Symbol.dispose is not a function");
                    }
                }
            }
            if (method == null) return self.throwError("TypeError", "using value has no Symbol.asyncDispose method");
        } else {
            // §ER GetDisposeMethod (sync-dispose): @@dispose, which must be callable.
            const sym = self.wellKnownSymbol("dispose") orelse return self.throwError("TypeError", "Symbol.dispose unavailable");
            const mc = try self.getSymbolProperty(v, sym);
            if (mc.isAbrupt()) return mc;
            method = try self.disposeMethodOf(mc.normal);
            if (method == null) {
                // §ER GetMethod: undefined/null → no method (then CreateDisposableResource throws),
                // a non-callable value → TypeError directly.
                if (mc.normal == .undefined or mc.normal == .null) {
                    return self.throwError("TypeError", "using value has no Symbol.dispose method");
                }
                return self.throwError("TypeError", "Symbol.dispose is not a function");
            }
        }
        try self.disposables.append(self.arena, .{ .value = v, .method = method, .is_async = is_async });
        return .{ .normal = .undefined };
    }

    /// §7.3.11 GetMethod tail: a callable function value → that function; undefined/null/non-callable
    /// → null (the caller decides whether null is a TypeError or a no-op).
    fn disposeMethodOf(self: *Interpreter, m: Value) EvalError!?*Object {
        _ = self;
        if (m != .object) return null;
        if (!isCallable(m.object)) return null;
        return m.object;
    }

    /// §ER DisposeResources — at scope exit, dispose every resource pushed since `marker` in REVERSE
    /// (LIFO) order, threading `completion` (the body's completion). A disposer that throws while a
    /// throw completion is already pending is aggregated into a `SuppressedError { error, suppressed }`
    /// (the newest disposer error becomes `.error`, the prior pending completion becomes `.suppressed`);
    /// otherwise the disposer's throw simply replaces a previously-normal completion. The popped
    /// resources are removed from the stack. For an `await using`, the dispose result is awaited
    /// (via the body's await substrate when available). A normal `completion` and no throwing disposer
    /// returns `completion` unchanged.
    fn disposeFrom(self: *Interpreter, marker: usize, completion: Completion) EvalError!Completion {
        var result = completion;
        // Reverse order over the slice pushed since `marker`.
        var i = self.disposables.items.len;
        while (i > marker) {
            i -= 1;
            const res = self.disposables.items[i];
            // §ER Dispose: result ← (method undefined) undefined : Call(method, V). For an `await
            // using`, the result is then Awaited — even when method is undefined (a null/undefined
            // async resource still yields a microtask boundary at disposal).
            var disp: Completion = .{ .normal = .undefined };
            if (res.method) |m| {
                disp = try self.callFunction(m, &.{}, res.value);
            }
            if (res.is_async and !disp.isAbrupt()) {
                disp = try self.awaitDisposeResult(disp.normal);
            }
            if (disp == .throw) {
                result = try self.combineDisposeError(disp.throw, result);
            }
        }
        // Pop the disposed resources.
        self.disposables.items.len = marker;
        return result;
    }

    /// §ER DisposeResources step 1.b: fold a disposer error into the pending completion. If the
    /// pending completion is itself a throw, build a SuppressedError `{ error: <new>, suppressed:
    /// <pending> }`; otherwise the disposer error becomes the (new) throw completion.
    fn combineDisposeError(self: *Interpreter, err: Value, pending: Completion) EvalError!Completion {
        if (pending != .throw) return .{ .throw = err };
        // SuppressedError { error: err, suppressed: pending.throw }.
        const g = self.globals orelse return .{ .throw = err };
        const ctor_b = g.lookup("SuppressedError") orelse return .{ .throw = err };
        if (ctor_b.value != .object) return .{ .throw = err };
        const sc = try self.callFunction(ctor_b.value.object, &.{ err, pending.throw }, .undefined);
        if (sc.isAbrupt()) return sc;
        return .{ .throw = sc.normal };
    }

    /// §7.1.1 ToPrimitive ( input, hint ) — convert a value to a primitive. Primitives pass through
    /// unchanged (the hot path: no allocation, no method calls). For an Object: if it has an
    /// `@@toPrimitive` method, call it with the hint string and require a primitive result; otherwise
    /// run §7.1.1.1 OrdinaryToPrimitive with the effective hint (a `default` hint behaves as `number`).
    /// Returns the primitive Value, or an abrupt `.throw` completion on a TypeError / a thrown method.
    pub fn toPrimitive(self: *Interpreter, v: Value, hint: PrimHint) EvalError!Completion {
        if (v != .object) return .{ .normal = v };
        const o = v.object;
        // §7.1.1 step 2.a: exoticToPrim = GetMethod(input, @@toPrimitive).
        if (self.wellKnownToPrimitive()) |sym| {
            const mc = try self.getSymbolProperty(v, sym);
            if (mc.isAbrupt()) return mc;
            const m = mc.normal;
            if (m != .undefined and m != .null) {
                if (m != .object or !isCallable(m.object)) {
                    return self.throwError("TypeError", "Symbol.toPrimitive is not a function");
                }
                const rc = try self.callFunction(m.object, &.{.{ .string = hint.str() }}, v);
                if (rc.isAbrupt()) return rc;
                // §7.1.1 step 2.c.iii: the result must be a primitive.
                if (rc.normal == .object) {
                    return self.throwError("TypeError", "Cannot convert object to primitive value");
                }
                return .{ .normal = rc.normal };
            }
        }
        // §7.1.1 step 3: no @@toPrimitive → OrdinaryToPrimitive; a `default` hint means `number`.
        const eff: PrimHint = if (hint == .string) .string else .number;
        return self.ordinaryToPrimitive(o, eff);
    }

    /// §7.1.1.1 OrdinaryToPrimitive ( O, hint ) — try `valueOf` then `toString` (or the reverse for a
    /// `string` hint); the first callable method whose result is a primitive wins. A TypeError if
    /// neither yields a primitive.
    fn ordinaryToPrimitive(self: *Interpreter, o: *Object, hint: PrimHint) EvalError!Completion {
        const names: [2][]const u8 = if (hint == .string)
            .{ "toString", "valueOf" }
        else
            .{ "valueOf", "toString" };
        for (names) |name| {
            const mc = try self.getProperty(.{ .object = o }, name);
            if (mc.isAbrupt()) return mc;
            const m = mc.normal;
            if (m == .object and isCallable(m.object)) {
                const rc = try self.callFunction(m.object, &.{}, .{ .object = o });
                if (rc.isAbrupt()) return rc;
                if (rc.normal != .object) return .{ .normal = rc.normal }; // primitive → done
            }
        }
        return self.throwError("TypeError", "Cannot convert object to primitive value");
    }

    /// §7.1.4 ToNumber in a coercion context: ToPrimitive (number hint) an object, then the pure
    /// numeric conversion. Primitives skip straight to the pure `toNumber` (hot path). A Symbol is a
    /// TypeError per §7.1.4 (surfaced here, not the pure helper's NaN).
    pub fn toNumberV(self: *Interpreter, v: Value) EvalError!Completion {
        const prim = switch (v) {
            .object => blk: {
                const pc = try self.toPrimitive(v, .number);
                if (pc.isAbrupt()) return pc;
                break :blk pc.normal;
            },
            else => v,
        };
        if (prim == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        // §7.1.4 step 2: ToNumber(BigInt) throws a TypeError (it does NOT silently become NaN).
        if (prim == .bigint) return self.throwError("TypeError", "Cannot convert a BigInt value to a number");
        return .{ .normal = .{ .number = toNumber(prim) } };
    }

    /// §7.1.5 ToIntegerOrInfinity — ToNumber, then NaN→0, truncate toward zero, ±Inf preserved. Returns
    /// the integral (or ±Inf) value as a Number; propagates an abrupt ToNumber completion.
    pub fn toIntegerOrInfinity(self: *Interpreter, v: Value) EvalError!Completion {
        const nc = try self.toNumberV(v);
        if (nc.isAbrupt()) return nc;
        const n = nc.normal.number;
        if (std.math.isNan(n)) return .{ .normal = .{ .number = 0 } };
        if (std.math.isInf(n)) return .{ .normal = .{ .number = n } };
        return .{ .normal = .{ .number = std.math.trunc(n) } };
    }

    /// §7.1.17 ToString in a coercion context: ToPrimitive (string hint) an object, then ToString.
    /// A Symbol is a TypeError (§7.1.17 step 3). Used by string `+` and template substitution.
    fn toStringCoerceV(self: *Interpreter, v: Value) EvalError!CoerceResult {
        const prim = switch (v) {
            .object => blk: {
                const pc = try self.toPrimitive(v, .string);
                if (pc.isAbrupt()) return .{ .abrupt = pc };
                break :blk pc.normal;
            },
            else => v,
        };
        if (prim == .symbol) return .{ .abrupt = try self.throwError("TypeError", "Cannot convert a Symbol value to a string") };
        return .{ .string = try self.toString(prim) };
    }

    /// §7.1.17 ToString as a Completion — public wrapper for the built-in libraries (JSON, etc.):
    /// `.normal` holds the coerced string Value; a Symbol argument is an abrupt TypeError.
    pub fn toStringValuePub(self: *Interpreter, v: Value) EvalError!Completion {
        return switch (try self.toStringCoerceV(v)) {
            .string => |s| .{ .normal = .{ .string = s } },
            .abrupt => |c| c,
        };
    }

    // ── §7.4 Iteration protocol (Symbol.iterator) ───────────────────────────────

    /// §7.3.12 HasProperty(arr, i) over the Array exotic + its prototype chain — used by the
    /// iteration/search family's hole check (a deleted own index can still be "present" via
    /// `Array.prototype[i]`, so it must be visited per §23.1.3.x's `HasProperty` step).
    pub fn arrayHasPropertyChain(self: *Interpreter, arr: *Object, i: usize) bool {
        if (arr.arrayHas(i)) return true;
        // Walk the prototype chain (ordinary objects + array exotics + the key string map).
        const key = numberToString(self.arena, @floatFromInt(i)) catch return false;
        var proto: ?*Object = arr.prototype;
        while (proto) |p| {
            if (p.kind == .array and p.arrayHas(i)) return true;
            if (p.getProp(key) != null) return true;
            proto = p.prototype;
        }
        return false;
    }

    /// §7.3.12 HasProperty(O, ToString(i)) over an ARBITRARY object + its prototype chain — the
    /// generic-array-like counterpart of `arrayHasPropertyChain`. An array exotic checks its dense /
    /// sparse store first; every kind then falls back to the string-keyed chain walk.
    pub fn hasIndexChain(self: *Interpreter, o: *Object, i: usize) bool {
        if (o.kind == .array and o.arrayHas(i)) return true;
        const key = numberToString(self.arena, @floatFromInt(i)) catch return false;
        var p: ?*Object = o;
        while (p) |obj| {
            if (obj.kind == .array and obj.arrayHas(i)) return true;
            if (obj.getProp(key) != null) return true;
            p = obj.prototype;
        }
        return false;
    }

    /// §7.3.18 LengthOfArrayLike ( obj ) = ToLength(Get(obj, "length")). Clamped to [0, 2^53-1].
    /// Throwing (a Symbol/BigInt length → TypeError via ToNumber). Returns the length, or the abrupt
    /// completion to propagate. The Array exotic short-circuits to its tracked length.
    pub fn lengthOfArrayLike(self: *Interpreter, o: *Object) EvalError!union(enum) { len: usize, abrupt: Completion } {
        if (o.kind == .array) return .{ .len = o.arrayLen() };
        const lc = try self.getProperty(.{ .object = o }, "length");
        if (lc.isAbrupt()) return .{ .abrupt = lc };
        const nc = try self.toNumberV(lc.normal);
        if (nc.isAbrupt()) return .{ .abrupt = nc };
        const n = nc.normal.number;
        const max_len: f64 = 9007199254740991.0; // 2^53 - 1
        const len: usize = if (std.math.isNan(n) or n <= 0) 0 else if (n > max_len) @intFromFloat(max_len) else @intFromFloat(@trunc(n));
        return .{ .len = len };
    }

    /// §7.3.4 Set(O, key, v, true) for an arbitrary object — Throw=true, so a failed [[Set]] (a
    /// getter-only accessor, a non-writable own data property, a new property on a non-extensible object,
    /// or a read-only String-wrapper index/length) raises a TypeError rather than silently no-op'ing
    /// (the in-place mutating Array methods rely on this). Emulates §10.1.9 OrdinarySet's success bit.
    pub fn setKeyThrow(self: *Interpreter, o: *Object, key: []const u8, v: Value) EvalError!Completion {
        // A `new String(s)` wrapper: the canonical integer indices [0, len) and `length` are read-only,
        // non-configurable own slots (§10.4.3) → any [[Set]] is rejected.
        if (o.primitive) |p| if (p == .string) {
            if (std.mem.eql(u8, key, "length")) return self.throwError("TypeError", "Cannot assign to read only property 'length' of String");
            if (parseIndex(key)) |idx| if (idx < p.string.len) {
                return self.throwError("TypeError", "Cannot assign to read only String index");
            };
        };
        // §10.1.9.2 OrdinarySetWithOwnDescriptor — resolve the property on the chain.
        if (o.getProp(key)) |loc| {
            switch (loc.pv.payload) {
                .accessor => |a| {
                    const setter = a.set orelse return self.throwError("TypeError", "Cannot set property with only a getter");
                    const sc = try self.callFunction(setter, &.{v}, .{ .object = o });
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = .undefined };
                },
                .data => {
                    // An OWN non-writable data property rejects; an INHERITED one is shadowed by a new own
                    // property (subject to extensibility).
                    if (o.properties.getPtr(key)) |own| {
                        if (own.payload == .data and !own.writable) {
                            return self.throwError("TypeError", "Cannot assign to read only property");
                        }
                        own.payload = .{ .data = v };
                        return .{ .normal = .undefined };
                    }
                    if (!o.extensible) return self.throwError("TypeError", "Cannot add property, object is not extensible");
                    try o.set(key, v);
                    return .{ .normal = .undefined };
                },
            }
        }
        // Absent everywhere: create iff extensible.
        if (!o.extensible) return self.throwError("TypeError", "Cannot add property, object is not extensible");
        try o.set(key, v);
        return .{ .normal = .undefined };
    }

    /// §7.3.4 Set(O, ToString(i), v, true) for an arbitrary object. Array exotic uses the element store.
    pub fn setIndexThrow(self: *Interpreter, o: *Object, i: usize, v: Value) EvalError!Completion {
        if (o.kind == .array) return self.arraySetThrow(o, i, v);
        return self.setKeyThrow(o, try numberToString(self.arena, @floatFromInt(i)), v);
    }

    /// §7.3.5 Set(O, "length", n, true) for an arbitrary object (the mutating methods' final length set).
    pub fn setLengthThrow(self: *Interpreter, o: *Object, n: usize) EvalError!Completion {
        if (o.kind == .array) return self.arraySetLenThrow(o, n);
        return self.setKeyThrow(o, "length", .{ .number = @floatFromInt(n) });
    }

    /// §7.3.10 DeletePropertyOrThrow(O, ToString(i)) for an arbitrary object — a non-configurable own
    /// property (incl. a String-wrapper index) rejects → TypeError. Array exotic deletes a true hole.
    pub fn deleteIndexThrow(self: *Interpreter, o: *Object, i: usize) EvalError!Completion {
        if (o.kind == .array) {
            if (o.array_frozen) return self.throwError("TypeError", "Cannot delete property of a frozen array");
            try o.arrayDelete(i);
            return .{ .normal = .undefined };
        }
        // A String-wrapper canonical index is non-configurable → DeletePropertyOrThrow rejects.
        if (o.primitive) |p| if (p == .string) {
            if (i < p.string.len) return self.throwError("TypeError", "Cannot delete read only String index");
        };
        const key = try numberToString(self.arena, @floatFromInt(i));
        const dc = try self.deleteProperty(.{ .object = o }, key);
        if (dc.isAbrupt()) return dc;
        if (dc.normal == .boolean and !dc.normal.boolean) {
            return self.throwError("TypeError", "Cannot delete property");
        }
        return .{ .normal = .undefined };
    }

    /// §7.1.18 ToObject ( argument ) restricted to the cases the Array.prototype methods meet: an object
    /// passes through; `undefined`/`null` throw; a primitive boxes into the matching wrapper so its
    /// indexed reads (notably a String's chars / length) are observable as own properties.
    pub fn toObjectForArrayLike(self: *Interpreter, v: Value) EvalError!union(enum) { obj: *Object, abrupt: Completion } {
        switch (v) {
            .object => |o| return .{ .obj = o },
            .undefined, .null => return .{ .abrupt = try self.throwError("TypeError", "Array.prototype method called on null or undefined") },
            .string => |s| {
                const w = try Object.create(self.arena, self.globalProto("String"));
                w.primitive = .{ .string = s };
                return .{ .obj = w };
            },
            else => {
                // number / boolean / symbol / bigint box into an ordinary wrapper with no indexed own
                // props (M-subset: length is absent → LengthOfArrayLike yields 0, which matches the spec
                // result for these — they have no "length").
                const w = try Object.create(self.arena, self.objectProto());
                w.primitive = v;
                return .{ .obj = w };
            },
        }
    }

    /// Public §7.1.4 ToNumber (throwing) for built-in modules — a Symbol/BigInt operand throws a
    /// TypeError, an object runs ToPrimitive(number). Used by Array methods whose arg coercion must be
    /// observable (e.g. `copyWithin(0, Symbol())` → TypeError).
    pub fn toNumberThrowing(self: *Interpreter, v: Value) EvalError!Completion {
        return self.toNumberV(v);
    }

    /// Public §7.1.5 ToIntegerOrInfinity for built-in modules (e.g. `with` / `flat` index/depth args).
    pub fn toIntegerOrInfinityPub(self: *Interpreter, v: Value) EvalError!Completion {
        return self.toIntegerOrInfinity(v);
    }

    /// Public [[Get]] wrapper for built-in modules (e.g. `Array.from` reading `.length` / indices of
    /// an array-like). Same semantics as the internal `getProperty` (invokes getters, throws on
    /// null/undefined base).
    pub fn getProperty2(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        return self.getProperty(base, key);
    }

    /// Public §20.1.3.6 Object.prototype.toString wrapper for built-in modules (Array.prototype.toString
    /// fallback when the object's `join` is not callable).
    pub fn objectPrototypeToString(self: *Interpreter, this_val: Value) EvalError!Completion {
        return builtin_object.objectToString(self, this_val);
    }

    /// §7.3.20 Invoke ( V, P, argumentsList ) = Call(? GetV(V, P), V, args). Used by
    /// Array.prototype.toLocaleString (it invokes each element's own `toLocaleString`).
    pub fn invokeMethod(self: *Interpreter, v: Value, name: []const u8, args: []const Value) EvalError!Completion {
        const mc = try self.getProperty(v, name);
        if (mc.isAbrupt()) return mc;
        if (mc.normal != .object or mc.normal.object.kind != .function) {
            return self.throwError("TypeError", "property is not a function");
        }
        return self.callFunction(mc.normal.object, args, v);
    }

    /// Does `value` expose a `[Symbol.iterator]` method (i.e. is it iterable)? Used by `Array.from` to
    /// choose the iterable branch over the array-like branch. A primitive String is iterable too, but
    /// the caller checks that separately.
    pub fn isArrayFromIterable(self: *Interpreter, value: Value) EvalError!bool {
        const iter_sym = self.wellKnownIterator() orelse return false;
        const mc = try self.getSymbolProperty(value, iter_sym);
        if (mc.isAbrupt()) return false;
        return mc.normal == .object and mc.normal.object.kind == .function;
    }

    /// Public wrapper for `iterateToList` (drain an iterable into `out`). Used by `Array.from`.
    pub fn iterateToListPub(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
        return self.iterateToList(value, out);
    }

    /// §23.1.2.1 Array.from iterable branch (steps 6.b–6.h): step the iterator, apply `map_fn` per
    /// element AS WE GO, and CreateDataProperty onto `out` at the running index. An abrupt completion
    /// from `next`/`map_fn` triggers IteratorClose then propagates — so an infinite iterator whose
    /// mapFn throws on the first element terminates immediately (no draining → no OOM). On success
    /// `out.array_length` is the count. Returns the abrupt completion if any, else normal/undefined.
    pub fn arrayFromIterate(self: *Interpreter, items: Value, out: *Object, map_fn: ?*Object, this_arg: Value) EvalError!Completion {
        const git = try self.getIterator(items);
        const iterator = switch (git) {
            .abrupt => |c| return c,
            .iterator => |i| i,
        };
        var k: usize = 0;
        while (true) {
            try self.tick(); // a genuinely infinite iterable fails via the watchdog, never hangs
            const step = try self.iteratorStep(iterator);
            switch (step) {
                .abrupt => |c| return c,
                .done => return .{ .normal = .undefined },
                .value => |v| {
                    var to_store = v;
                    if (map_fn) |f| {
                        const r = try self.callFunction(f, &.{ v, .{ .number = @floatFromInt(k) } }, this_arg);
                        if (r.isAbrupt()) {
                            try self.iteratorClose(iterator); // §7.4.11 close on abrupt mapFn
                            return r;
                        }
                        to_store = r.normal;
                    }
                    const dc = try self.createDataPropertyOrThrow(out, k, to_store);
                    if (dc.isAbrupt()) {
                        try self.iteratorClose(iterator); // §7.4.11 close on a failed CreateDataProperty
                        return dc;
                    }
                    k += 1;
                },
            }
        }
    }

    /// The realm's well-known `Symbol.iterator` identity (the same value held on the `Symbol`
    /// constructor), used by GetIterator. Null only in a realm-less unit-test eval (no `Symbol`).
    pub fn wellKnownIterator(self: *Interpreter) ?*Symbol {
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

    /// The realm's well-known `Symbol.asyncIterator` identity (held on the `Symbol` constructor).
    fn wellKnownAsyncIterator(self: *Interpreter) ?*Symbol {
        const g = self.globals orelse return null;
        const b = g.lookup("Symbol") orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("asyncIterator") orelse return null;
        return if (pv == .symbol) pv.symbol else null;
    }

    /// §7.4.3 GetIterator ( obj, async ) — read `obj[Symbol.asyncIterator]`; if present, call it (the
    /// result is the async iterator). If ABSENT, fall back to the SYNC iterator (`obj[Symbol.iterator]`)
    /// and wrap it in an AsyncFromSyncIterator (§27.1.4.1 CreateAsyncFromSyncIterator) so `for await`
    /// can drive a sync iterable. A value with neither → TypeError.
    fn getAsyncIterator(self: *Interpreter, obj: Value) EvalError!IterResult {
        if (self.wellKnownAsyncIterator()) |async_sym| {
            const mc = try self.getSymbolProperty(obj, async_sym);
            if (mc.isAbrupt()) return .{ .abrupt = mc };
            if (mc.normal == .object and mc.normal.object.kind == .function) {
                const rc = try self.callFunction(mc.normal.object, &.{}, obj);
                if (rc.isAbrupt()) return .{ .abrupt = rc };
                if (rc.normal != .object) {
                    return .{ .abrupt = try self.throwError("TypeError", "Result of Symbol.asyncIterator is not an object") };
                }
                return .{ .iterator = rc.normal.object };
            }
            // §7.4.3 step 1.b.i: an undefined/null [Symbol.asyncIterator] (or absent) → use the sync path.
            if (mc.normal != .undefined and mc.normal != .null) {
                return .{ .abrupt = try self.throwError("TypeError", "Symbol.asyncIterator is not callable") };
            }
        }
        // §27.1.4.1 CreateAsyncFromSyncIterator: get the SYNC iterator, wrap it.
        const sync = try self.getIterator(obj);
        const sync_iter: *Object = switch (sync) {
            .abrupt => |c| return .{ .abrupt = c },
            .iterator => |it| it,
        };
        const wrapper = try Object.create(self.arena, self.asyncFromSyncProto());
        wrapper.async_from_sync = sync_iter;
        return .{ .iterator = wrapper };
    }

    pub const StepResult = union(enum) { value: Value, done, abrupt: Completion };

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
    pub fn iteratorClose(self: *Interpreter, iterator: *Object) EvalError!void {
        const rc = try self.getProperty(.{ .object = iterator }, "return");
        if (rc.isAbrupt()) return; // swallow — don't mask the original completion
        if (rc.normal != .object or rc.normal.object.kind != .function) return;
        // A throwing `return()` is swallowed (the original completion wins, §7.4.11 step 4); but an
        // engine error (OOM / step-limit) still propagates via `try`.
        _ = try self.callFunction(rc.normal.object, &.{}, .{ .object = iterator });
    }

    /// §7.4.11 IteratorClose for a NORMAL (non-throw) incoming completion — the iterator is being
    /// closed early on `break` / loop-exiting `continue` / `return`, so a thrown `return()` (or a
    /// non-Object `return()` result) MUST propagate (steps 5–6), unlike the throw-completion case
    /// (`iteratorClose`, step 4, which swallows). Returns `.normal` on a clean close, else the abrupt
    /// completion to propagate. GetMethod semantics: undefined/null `return` → no-op; non-callable →
    /// TypeError (§7.3.10).
    fn iteratorCloseChecked(self: *Interpreter, iterator: *Object) EvalError!Completion {
        const rc = try self.getProperty(.{ .object = iterator }, "return");
        if (rc.isAbrupt()) return rc; // a throwing `return` getter propagates
        if (rc.normal == .undefined or rc.normal == .null) return .{ .normal = .undefined };
        if (rc.normal != .object or rc.normal.object.kind != .function)
            return self.throwError("TypeError", "iterator 'return' is not a function");
        const res = try self.callFunction(rc.normal.object, &.{}, .{ .object = iterator });
        if (res.isAbrupt()) return res; // §7.4.11 step 5: a thrown `return()` propagates
        if (res.normal != .object) return self.throwError("TypeError", "iterator 'return' result is not an object"); // step 6
        return .{ .normal = .undefined };
    }

    /// §7.4.1 GetIterator + drain — materialize an iterable `value` into a slice of its yielded values
    /// via the full Symbol.iterator protocol. Used by spread / array destructuring (which need the
    /// whole sequence up front). Arrays/Strings have native iterators (fast), but ANY object with a
    /// `[Symbol.iterator]` returning a `next`-having object works. A non-iterable → abrupt TypeError.
    pub fn iterateToList(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
        // Fast path: an Array iterates its `elements` directly (skips the per-element next() call),
        // preserving the hot spread/destructuring path. Strings keep their native code-unit walk.
        if (value == .object and value.object.kind == .array) {
            const arr = value.object;
            const len = arr.arrayLen();
            if (len == arr.elements.items.len) {
                for (arr.elements.items) |el| try out.append(self.arena, el); // pure dense (hot path)
            } else {
                var i: usize = 0; // sparse tail: holes spread as `undefined` (§13.2.4)
                while (i < len) : (i += 1) try out.append(self.arena, arr.arrayGet(i));
            }
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
                    try self.tick(); // §reliability: a genuinely infinite iterable fails via the watchdog, never hangs
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

    /// §8.5.2 IteratorBindingInitialization / §13.15.5.3 IteratorDestructuringAssignmentEvaluation —
    /// an iterator record driven ONE STEP AT A TIME by array-pattern destructuring (binding & assignment).
    /// Unlike `iterateToList` it does NOT drain: each pattern element advances the iterator exactly once
    /// (so an infinite iterator destructured by a fixed pattern is fine), and when the pattern is
    /// satisfied without a rest element the iterator is closed via IteratorClose (§7.4.11) if not done.
    ///
    /// A plain Array (default iterator) is fast-pathed over `.elements` with no observable iterator
    /// calls — the difference (no `next`/`return` invocation) is unobservable for the built-in iterator,
    /// so we never construct one. Any other iterable goes through the real §7.4 protocol.
    const ArrayDestr = union(enum) {
        /// Plain Array fast path: a cursor over the backing `elements` (no iterator object exists).
        fast: struct { items: []const Value, idx: usize = 0 },
        /// General iterable: a §7.4 iterator record. `done` mirrors IteratorRecord.[[Done]].
        iter: struct { iterator: *Object, done: bool = false },

        fn isDone(self: ArrayDestr) bool {
            return switch (self) {
                .fast => |f| f.idx >= f.items.len,
                .iter => |it| it.done,
            };
        }
    };

    /// §8.5.2 step: advance the array-destructuring iterator exactly once. Returns the produced value
    /// (or `undefined` once the iterator is done — IteratorStep returned done, per §13.15.5.3 step 4),
    /// or an abrupt completion if `next()` throws. After a done step the record is marked done so later
    /// elements short-circuit to `undefined` without further `next()` calls (§8.5.2 4.a).
    fn destrStep(self: *Interpreter, rec: *ArrayDestr) EvalError!Completion {
        switch (rec.*) {
            .fast => |*f| {
                if (f.idx >= f.items.len) return .{ .normal = .undefined };
                const v = f.items[f.idx];
                f.idx += 1;
                return .{ .normal = v };
            },
            .iter => |*it| {
                if (it.done) return .{ .normal = .undefined };
                try self.tick(); // §reliability: a bounded watchdog even though a fixed pattern steps finitely
                const step = try self.iteratorStep(it.iterator);
                switch (step) {
                    .abrupt => |c| {
                        // §7.4.4: an abrupt IteratorStep sets [[Done]] = true (the iterator self-closed).
                        it.done = true;
                        return c;
                    },
                    .done => {
                        it.done = true;
                        return .{ .normal = .undefined };
                    },
                    .value => |v| return .{ .normal = v },
                }
            },
        }
    }

    /// §13.15.5.3 BindingRestElement / AssignmentRestElement — drain the REMAINDER of the iterator into a
    /// fresh Array. This is the ONLY destructuring path that consumes to completion; the rest-drain loop
    /// is step-bounded so an infinite iterable fails via the watchdog rather than hanging.
    fn destrRest(self: *Interpreter, rec: *ArrayDestr) EvalError!union(enum) { array: *Object, abrupt: Completion } {
        const arr = try Object.createArray(self.arena, self.arrayProto());
        switch (rec.*) {
            .fast => |*f| {
                while (f.idx < f.items.len) : (f.idx += 1) try arr.elements.append(self.arena, f.items[f.idx]);
            },
            .iter => |*it| {
                while (!it.done) {
                    try self.tick(); // §reliability: a rest over an infinite iterable terminates via the watchdog
                    const step = try self.iteratorStep(it.iterator);
                    switch (step) {
                        .abrupt => |c| {
                            it.done = true;
                            return .{ .abrupt = c };
                        },
                        .done => it.done = true,
                        .value => |v| try arr.elements.append(self.arena, v),
                    }
                }
            },
        }
        return .{ .array = arr };
    }

    /// §7.4.11 IteratorClose after a destructuring pattern WITHOUT a rest element: if the record is a
    /// real iterator that is not yet done, call its `return()`. The plain-Array fast path has no iterator
    /// object, so closing is a no-op. On an abrupt `completion` the original throw is preserved (a
    /// throwing `return()` is swallowed; an engine error still propagates).
    fn destrClose(self: *Interpreter, rec: ArrayDestr) EvalError!void {
        switch (rec) {
            .fast => {},
            .iter => |it| if (!it.done) try self.iteratorClose(it.iterator),
        }
    }

    /// §7.4.11 IteratorClose after a destructuring pattern that completed NORMALLY (no rest, iterator
    /// not done): a throwing `return()` (or a non-object result) MUST propagate — unlike `destrClose`,
    /// used after an abrupt completion, which swallows (§7.4.11 step 4). Returns `.normal` on a clean
    /// close (incl. the fast Array path, which has no iterator object).
    fn destrCloseChecked(self: *Interpreter, rec: ArrayDestr) EvalError!Completion {
        switch (rec) {
            .fast => return .{ .normal = .undefined },
            .iter => |it| return if (it.done) .{ .normal = .undefined } else self.iteratorCloseChecked(it.iterator),
        }
    }

    /// GetIterator(value) once for array destructuring, choosing the unobservable fast path for a plain
    /// Array (default iterator) and the §7.4 protocol otherwise. A non-iterable → abrupt TypeError.
    fn destrOpen(self: *Interpreter, value: Value) EvalError!union(enum) { driver: ArrayDestr, abrupt: Completion } {
        if (value == .object and value.object.kind == .array) {
            const arr = value.object;
            const len = arr.arrayLen();
            if (len == arr.elements.items.len) {
                return .{ .driver = .{ .fast = .{ .items = arr.elements.items } } }; // pure dense (hot path)
            }
            // Sparse: materialize length items (holes → `undefined`) once, then drive the fast path.
            var items: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < len) : (i += 1) try items.append(self.arena, arr.arrayGet(i));
            return .{ .driver = .{ .fast = .{ .items = items.items } } };
        }
        if (value == .string) {
            // A String iterates code units; materialize once (finite) and drive the fast path over them.
            const s = value.string;
            var units: std.ArrayListUnmanaged(Value) = .empty;
            for (0..s.len) |i| try units.append(self.arena, .{ .string = s[i .. i + 1] });
            return .{ .driver = .{ .fast = .{ .items = units.items } } };
        }
        const git = try self.getIterator(value);
        return switch (git) {
            .abrupt => |c| .{ .abrupt = c },
            .iterator => |iterator| .{ .driver = .{ .iter = .{ .iterator = iterator } } },
        };
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
        // §15.5.2 EvaluateGeneratorBody step 1: FunctionDeclarationInstantiation runs EAGERLY here (on
        // the caller thread), so a param destructuring/default error throws at the call site, before
        // the generator object is created/returned and before any `.next`.
        var abrupt: ?Completion = null;
        gen.call_env = try self.instantiateGeneratorParams(gen, &abrupt);
        if (abrupt) |c| return c;
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
    /// §9.2.6 FunctionDeclarationInstantiation for a generator/async-generator body — bind the params
    /// (incl. destructuring patterns + default-value expressions) and the `arguments` object into a
    /// fresh environment, returning it. Per §15.5.2 EvaluateGeneratorBody / §15.6.2
    /// EvaluateAsyncGeneratorBody this runs EAGERLY when the generator object is created (on the caller
    /// thread), so a destructuring/default error surfaces at the call site rather than at first `.next`.
    /// An abrupt completion (a thrown default/pattern error) is returned via the `Completion` out-param.
    fn instantiateGeneratorParams(self: *Interpreter, gen: *object_mod.Generator, abrupt: *?Completion) EvalError!*Environment {
        abrupt.* = null;
        const fd = gen.func.call.?;
        const args = gen.args;
        const call_env = try Environment.create(self.arena, fd.closure);
        call_env.is_var_scope = true; // §10.2.11: a generator/async FunctionBody is a VariableEnvironment
        for (fd.params, 0..) |param, i| {
            var v: Value = if (i < args.len) args[i] else .undefined;
            var defaulted = false;
            if (v == .undefined) {
                if (param.default) |dn| {
                    const dc = try self.evalExpr(dn, call_env);
                    if (dc.isAbrupt()) {
                        abrupt.* = dc;
                        return call_env;
                    }
                    v = dc.normal;
                    defaulted = true;
                }
            }
            if (param.pattern.* == .identifier) {
                // §15.1.3: name an anonymous fn/class default initializer on a SingleNameBinding.
                if (defaulted) try self.maybeSetAnonName(param.default.?, v, param.pattern.identifier);
                try call_env.declare(param.pattern.identifier, v, true, true);
            } else {
                const bc = try self.bindPattern(param.pattern, v, call_env, true);
                if (bc.isAbrupt()) {
                    abrupt.* = bc;
                    return call_env;
                }
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
                if (bc.isAbrupt()) {
                    abrupt.* = bc;
                    return call_env;
                }
            }
        }
        if (call_env.lookupLocal("arguments") == null) {
            const ao = try self.makeArgumentsObject(args, gen.func, call_env, fd);
            try call_env.declare("arguments", .{ .object = ao }, true, true);
        }
        return call_env;
    }

    fn runGeneratorBody(self: *Interpreter, gen: *object_mod.Generator) EvalError!Completion {
        const func = gen.func;
        const fd = func.call.?;
        // §15.5.2/§15.6.2: a sync/async GENERATOR's params were already bound on the caller thread
        // (`gen.call_env` set in createGenerator/createAsyncGenerator). An ASYNC FUNCTION binds them
        // here on the body thread (a param error rejects the promise — see callAsyncFunction).
        var abrupt: ?Completion = null;
        const call_env = gen.call_env orelse try self.instantiateGeneratorParams(gen, &abrupt);
        if (abrupt) |c| return c;
        self.this_val = gen.this_val;
        self.home_object = gen.home_object;
        // §11.2.2: the generator/async body runs in its own strict context (this fresh body interpreter
        // started sloppy). A strict body's §6.2.5.6 PutValue to an unresolved name must throw.
        self.strict = fd.strict;
        // §10.2.11 (lexical step): hoist the body's top-level `let`/`const`/`class` names as TDZ bindings.
        try self.hoistLexicalNames(fd.body, call_env);
        // §10.2.11 (var step): instantiate VarDeclaredNames in the body VariableEnvironment.
        try self.hoistVarNames(fd.body, call_env);
        // §ER: a GeneratorBody / AsyncFunctionBody / AsyncGeneratorBody lexically containing a
        // `using`/`await using` disposes its resources on body exit (return OR throw). Gated on
        // `blockHasUsing` so an ordinary body pays nothing.
        if (blockHasUsing(fd.body)) {
            const marker = self.disposables.items.len;
            var body_c: Completion = .{ .normal = .undefined };
            for (fd.body) |stmt| {
                const c = try self.evalStmt(stmt, call_env);
                switch (c) {
                    .normal => {},
                    .ret, .throw => {
                        body_c = c;
                        break;
                    },
                    .brk, .cont => {},
                }
            }
            const disposed = try self.disposeFrom(marker, body_c);
            return switch (disposed) {
                .ret => |v| .{ .normal = v },
                .throw => disposed,
                else => .{ .normal = .undefined },
            };
        }
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

    /// Call `iterator[method](arg)` and return its RAW result value (no IteratorResult decode). Used by
    /// `for await` (the result is a promise to be awaited before decoding) and by async `yield*`. A
    /// missing/non-callable method → TypeError. `pass_arg` false calls with no argument.
    fn iteratorCallRaw(self: *Interpreter, iterator: *Object, method: []const u8, arg: Value, pass_arg: bool) EvalError!Completion {
        const mc = try self.getProperty(.{ .object = iterator }, method);
        if (mc.isAbrupt()) return mc;
        if (mc.normal != .object or mc.normal.object.kind != .function) {
            return self.throwError("TypeError", "iterator method is not a function");
        }
        const args: []const Value = if (pass_arg) &.{arg} else &.{};
        return self.callFunction(mc.normal.object, args, .{ .object = iterator });
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

    // ── §27.2 Promise + §9.5 Job (microtask) queue + §27.7 async functions ───────
    //
    // A Promise object carries a PromiseData slot (state / result / reaction lists). `then` queues a
    // reaction; on settlement each reaction becomes a Job on the realm queue. The engine drains the
    // queue once the synchronous stack is empty (`drainJobs`, step-bounded — no hangs). An async
    // function reuses the GENERATOR thread substrate: its body runs on a std.Thread, suspending at each
    // `await` via the ping-pong handoff (`Generator.is_async = true`); the awaited value is carried out,
    // the caller registers fulfill/reject reactions on it, and the reaction Jobs resume the body thread.

    /// %PromisePrototype% — the [[Prototype]] of every Promise object. Stashed under a sentinel global
    /// name by `builtins.setup` (like %GeneratorPrototype%). Null only in a realm-less unit eval.
    fn promiseProto(self: *Interpreter) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup("%PromisePrototype%") orelse return null;
        return if (b.value == .object) b.value.object else null;
    }

    /// §27.2.3.1 CreatePromise / NewPromiseCapability — a fresh pending Promise object (proto =
    /// %PromisePrototype%) with empty reaction lists.
    fn newPromise(self: *Interpreter) EvalError!*Object {
        const obj = try Object.create(self.arena, self.promiseProto());
        const pd = try self.arena.create(object_mod.PromiseData);
        pd.* = .{};
        obj.promise = pd;
        return obj;
    }

    /// §9.5 HostEnqueuePromiseJob — append a Job to the realm's microtask FIFO (drained when the stack
    /// is empty). A realm-less eval (no `job_queue`) silently drops it (no promises reach here).
    fn enqueueJob(self: *Interpreter, job: object_mod.Job) EvalError!void {
        const q = self.job_queue orelse return;
        try q.append(self.arena, job);
    }

    /// §27.2.1.4 FulfillPromise — transition a pending promise to fulfilled with `value` and schedule
    /// its fulfill reactions as Jobs (then clear both reaction lists).
    fn fulfillPromise(self: *Interpreter, promise: *Object, value: Value) EvalError!void {
        const pd = promise.promise.?;
        if (pd.state != .pending) return;
        pd.result = value;
        pd.state = .fulfilled;
        for (pd.fulfill_reactions.items) |reaction| {
            try self.enqueueJob(.{ .reaction = .{ .reaction = reaction, .argument = value } });
        }
        pd.fulfill_reactions.clearRetainingCapacity();
        pd.reject_reactions.clearRetainingCapacity();
    }

    /// §27.2.1.7 RejectPromise — transition a pending promise to rejected with `reason` and schedule
    /// its reject reactions as Jobs.
    fn rejectPromise(self: *Interpreter, promise: *Object, reason: Value) EvalError!void {
        const pd = promise.promise.?;
        if (pd.state != .pending) return;
        pd.result = reason;
        pd.state = .rejected;
        for (pd.reject_reactions.items) |reaction| {
            try self.enqueueJob(.{ .reaction = .{ .reaction = reaction, .argument = reason } });
        }
        pd.fulfill_reactions.clearRetainingCapacity();
        pd.reject_reactions.clearRetainingCapacity();
    }

    /// §27.2.1.3.2 the resolve function's behavior — resolve `promise` with `resolution`. If
    /// `resolution` is the promise itself → reject with a TypeError (chaining cycle). If it is a
    /// thenable (an object with a callable `then`) → enqueue a PromiseResolveThenableJob to adopt its
    /// eventual state. Otherwise fulfill with the value. `already_resolved` guards single settlement.
    fn resolvePromise(self: *Interpreter, promise: *Object, resolution: Value) EvalError!void {
        const pd = promise.promise.?;
        if (pd.already_resolved) return;
        pd.already_resolved = true;
        // §27.2.1.3.2 step 6: resolving a promise with itself is a TypeError rejection.
        if (resolution == .object and resolution.object == promise) {
            const tc = try self.throwError("TypeError", "Chaining cycle detected for promise");
            return self.rejectPromiseRaw(promise, tc.throw);
        }
        if (resolution != .object) return self.fulfillPromiseRaw(promise, resolution);
        // §27.2.1.3.2 step 8–9: read `resolution.then`; a throw there rejects the promise.
        const then_c = try self.getProperty(resolution, "then");
        if (then_c.isAbrupt()) return self.rejectPromiseRaw(promise, then_c.throw);
        const then_v = then_c.normal;
        if (then_v != .object or !isCallable(then_v.object)) {
            // §27.2.1.3.2 step 10: not a thenable → fulfill with the resolution value.
            return self.fulfillPromiseRaw(promise, resolution);
        }
        // §27.2.1.3.2 step 12: a thenable → adopt its state via a job (calls then(resolve, reject)).
        try self.enqueueJob(.{ .thenable = .{ .promise = promise, .thenable = resolution, .then_fn = then_v.object } });
    }

    /// Internal fulfill that bypasses the [[AlreadyResolved]] guard (used by `resolvePromise` after it
    /// has claimed resolution). Identical to FulfillPromise.
    fn fulfillPromiseRaw(self: *Interpreter, promise: *Object, value: Value) EvalError!void {
        return self.fulfillPromise(promise, value);
    }

    /// Internal reject that ALSO marks already_resolved (the resolve-function path must block a later
    /// resolve). Mirrors §27.2.1.3.1 setting [[AlreadyResolved]] before rejecting.
    fn rejectPromiseRaw(self: *Interpreter, promise: *Object, reason: Value) EvalError!void {
        promise.promise.?.already_resolved = true;
        return self.rejectPromise(promise, reason);
    }

    /// Build a resolve or reject function object (§27.2.1.3) bound to `promise` via `promise_slot`.
    fn makeResolvingFunction(self: *Interpreter, promise: *Object, id: object_mod.NativeId) EvalError!*Object {
        const f = try Object.createNative(self.arena, id, "");
        f.prototype = self.functionProto();
        f.promise_slot = promise;
        return f;
    }

    /// §27.2.4.7 PromiseResolve(x) — if `x` is already a promise, return it; otherwise wrap it in a
    /// fresh resolved promise. Used by `Promise.resolve` and by `await` (§27.7.5.3 step 2). (M-subset:
    /// no subclass/species — every promise is a %Promise%, so the "is it already a promise" test is the
    /// `.promise != null` slot check.)
    fn promiseResolveValue(self: *Interpreter, x: Value) EvalError!*Object {
        if (x == .object and x.object.promise != null) return x.object;
        const p = try self.newPromise();
        try self.resolvePromise(p, x);
        return p;
    }

    /// §27.2.5.4.1 PerformPromiseThen — attach a fulfill/reject reaction pair to `promise`, returning
    /// the derived result promise (`capability`). If `promise` is already settled, the matching
    /// reaction is enqueued as a Job immediately; otherwise it is appended to the pending list.
    /// `on_fulfilled`/`on_rejected` are the user handlers (null ⇒ default pass-through). When
    /// `result_promise` is provided it is used as the capability (so `await`/internal callers can pass
    /// null for "no derived promise"); a normal `then` always creates one.
    fn performPromiseThen(self: *Interpreter, promise: *Object, on_fulfilled: ?*Object, on_rejected: ?*Object, capability: ?*Object) EvalError!void {
        const pd = promise.promise.?;
        const fulfill_reaction: object_mod.PromiseReaction = .{ .kind = .fulfill, .handler = on_fulfilled, .capability = capability };
        const reject_reaction: object_mod.PromiseReaction = .{ .kind = .reject, .handler = on_rejected, .capability = capability };
        switch (pd.state) {
            .pending => {
                try pd.fulfill_reactions.append(self.arena, fulfill_reaction);
                try pd.reject_reactions.append(self.arena, reject_reaction);
            },
            .fulfilled => try self.enqueueJob(.{ .reaction = .{ .reaction = fulfill_reaction, .argument = pd.result } }),
            .rejected => try self.enqueueJob(.{ .reaction = .{ .reaction = reject_reaction, .argument = pd.result } }),
        }
    }

    /// §27.2.2.1 PromiseReactionJob — run one settled-promise reaction (the body of a queued Job). For
    /// a user handler: call it with the settlement value; resolve the derived capability with the
    /// result (or reject it if the handler throws). For a DEFAULT handler (null): fulfill→resolve the
    /// capability with the value; reject→reject it with the reason (§27.2.4.7.1/.2). For an AWAIT
    /// reaction (`await_gen` set): resume the awaiting async body thread (fulfill→`.next(value)`,
    /// reject→`.throw(value)`) instead. Runs on the MAIN interpreter while draining the queue.
    fn runReactionJob(self: *Interpreter, reaction: object_mod.PromiseReaction, argument: Value) EvalError!void {
        // §27.7.5.3 await: a reaction with no capability/handler resumes the parked async body thread.
        if (reaction.await_gen) |gen| {
            const kind: object_mod.ResumeKind = if (reaction.kind == .fulfill) .next else .throw;
            // §27.6.3.8: an async-GENERATOR body resumes through the request-queue servicer (settles
            // requests as it advances); a plain async function resumes through `resumeAsync`.
            if (gen.is_async_gen) return self.asyncGenResumeAfterAwait(gen, kind, argument);
            return self.resumeAsync(gen, kind, argument);
        }
        const cap = reaction.capability;
        if (reaction.handler) |h| {
            const hc = try self.callFunction(h, &.{argument}, .undefined);
            if (cap) |c| {
                switch (hc) {
                    .normal => |v| try self.resolvePromise(c, v),
                    .throw => |e| try self.rejectPromiseRaw(c, e),
                    else => {},
                }
            }
            return;
        }
        // Default handler (§27.2.4.7.1 identity / §27.2.4.7.2 thrower).
        if (cap) |c| switch (reaction.kind) {
            .fulfill => try self.resolvePromise(c, argument),
            .reject => try self.rejectPromiseRaw(c, argument),
        };
    }

    /// §27.2.2.2 PromiseResolveThenableJob — `promise` was resolved with a thenable; call
    /// `thenable.then(resolveFn, rejectFn)` so the thenable drives `promise`'s eventual settlement. A
    /// throw from `then` rejects `promise`.
    fn runThenableJob(self: *Interpreter, promise: *Object, thenable: Value, then_fn: *Object) EvalError!void {
        // §27.2.2.2 step 1: CreateResolvingFunctions(promise) — a FRESH [[AlreadyResolved]] record
        // (the original resolve already fired into THIS job and set the promise's flag). Clear the
        // promise's already_resolved so the thenable's resolve/reject can settle it; from here only
        // these new functions act on the promise, so this is the single fresh resolution gate.
        promise.promise.?.already_resolved = false;
        const resolve_fn = try self.makeResolvingFunction(promise, .promise_resolve_fn);
        const reject_fn = try self.makeResolvingFunction(promise, .promise_reject_fn);
        const rc = try self.callFunction(then_fn, &.{ .{ .object = resolve_fn }, .{ .object = reject_fn } }, thenable);
        if (rc == .throw) {
            // §27.2.2.2 step 4: a throw from `then` rejects the promise (if not already resolved).
            try self.resolvePromiseReject(promise, rc.throw);
        }
    }

    /// Reject `promise` honoring [[AlreadyResolved]] (used when a thenable's `then` throws): only the
    /// FIRST settlement wins, so a `then` that both called resolve and then threw is a no-op here.
    fn resolvePromiseReject(self: *Interpreter, promise: *Object, reason: Value) EvalError!void {
        const pd = promise.promise.?;
        if (pd.already_resolved) return;
        pd.already_resolved = true;
        return self.rejectPromise(promise, reason);
    }

    /// §9.5 drain the Job (microtask) queue to completion: while non-empty, dequeue (FIFO) and run the
    /// front job; each job may enqueue more. Bounded by the interpreter step limit — a runaway microtask
    /// loop (e.g. a promise that re-schedules itself forever) terminates via StepLimitExceeded rather
    /// than hanging. Runs on the MAIN interpreter after the synchronous script completes. A job that
    /// throws unhandled is swallowed (an unhandled rejection is not a host error — there is no host).
    pub fn drainJobs(self: *Interpreter) EvalError!void {
        const q = self.job_queue orelse return;
        var head: usize = 0;
        while (head < q.items.len) {
            try self.tick(); // §9.5 bound the drain by the step watchdog (no hangs)
            const job = q.items[head];
            head += 1;
            switch (job) {
                .reaction => |r| {
                    // A reaction job may itself throw (the handler / await resume); swallow it — there
                    // is no host to report an unhandled rejection to, and the derived promise (if any)
                    // already captured the outcome inside runReactionJob.
                    self.runReactionJob(r.reaction, r.argument) catch |e| {
                        if (e == error.StepLimitExceeded) return e; // the watchdog must propagate
                    };
                },
                .thenable => |t| {
                    self.runThenableJob(t.promise, t.thenable, t.then_fn) catch |e| {
                        if (e == error.StepLimitExceeded) return e;
                    };
                },
            }
            // Periodically compact the consumed prefix so a long-running drain doesn't grow unbounded.
            if (head >= 256 and head * 2 >= q.items.len) {
                std.mem.copyForwards(object_mod.Job, q.items[0 .. q.items.len - head], q.items[head..]);
                q.items.len -= head;
                head = 0;
            }
        }
        q.clearRetainingCapacity();
    }

    // ── §27.7 async functions (thread-suspended body, await ↔ promise reactions) ─

    /// §27.7.5.1 AsyncFunctionStart — calling an async function returns a Promise immediately and runs
    /// the body on a generator-style thread. The body suspends at each `await`; on normal return the
    /// promise fulfills, on an uncaught throw it rejects. Reuses the `Generator` substrate with
    /// `is_async = true` and runs to the FIRST suspension (await) or completion synchronously (so the
    /// returned promise is already settled when the body has no awaits).
    fn callAsyncFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        const promise = try self.newPromise();
        const gen = try self.arena.create(object_mod.Generator);
        const args_copy = try self.arena.dupe(Value, args);
        gen.* = .{
            .func = func,
            .args = args_copy,
            .this_val = this_val,
            .home_object = if (func.call) |fd| fd.home_object else null,
            .is_async = true,
            .promise = promise,
        };
        if (self.gen_registry) |reg| try reg.append(self.arena, gen);
        // §27.7.5.2 AsyncBlockStart: spawn the body thread and run it to the first await / completion.
        gen.state = .executing;
        gen.resume_kind = .next;
        gen.sent_value = .undefined;
        const t = std.Thread.spawn(.{}, asyncBodyThread, .{ self, gen }) catch {
            gen.state = .completed;
            return self.throwError("RangeError", "Cannot spawn async function thread");
        };
        gen.thread = t;
        gen.to_caller.waitUncancelable(self.io); // wait for the first await suspension / completion
        try self.settleAsyncTransfer(gen);
        return .{ .normal = .{ .object = promise } };
    }

    /// Resume a suspended async body (from a settled-await reaction Job) with `kind`/`value`, run it to
    /// the next await / completion, and process the resulting transfer. `.next` → the await evaluates to
    /// `value`; `.throw` → the await throws `value` into the body.
    fn resumeAsync(self: *Interpreter, gen: *object_mod.Generator, kind: object_mod.ResumeKind, value: Value) EvalError!void {
        if (gen.state == .completed) return; // a settled body never resumes (defensive)
        gen.state = .executing;
        gen.resume_kind = kind;
        gen.sent_value = value;
        gen.resume_gen.post(self.io); // wake the parked await
        gen.to_caller.waitUncancelable(self.io); // wait for the next await / completion
        try self.settleAsyncTransfer(gen);
    }

    /// After an async body handoff: an `await` transfer (kind `.yield`) registers fulfill/reject
    /// reactions on the awaited promise that will resume the body; a terminal `.ret`/`.throw` resolves
    /// /rejects the function's promise and joins the thread (§27.7.5.2).
    fn settleAsyncTransfer(self: *Interpreter, gen: *object_mod.Generator) EvalError!void {
        switch (gen.transfer_kind) {
            .yield => {
                // §27.7.5.3 Await: `transfer_value` is the AWAITED value. Wrap it via PromiseResolve and
                // register internal reactions that resume THIS body on settlement.
                gen.state = .suspended_yield;
                const awaited = try self.promiseResolveValue(gen.transfer_value);
                const on_f: object_mod.PromiseReaction = .{ .kind = .fulfill, .handler = null, .capability = null, .await_gen = gen };
                const on_r: object_mod.PromiseReaction = .{ .kind = .reject, .handler = null, .capability = null, .await_gen = gen };
                const pd = awaited.promise.?;
                switch (pd.state) {
                    .pending => {
                        try pd.fulfill_reactions.append(self.arena, on_f);
                        try pd.reject_reactions.append(self.arena, on_r);
                    },
                    .fulfilled => try self.enqueueJob(.{ .reaction = .{ .reaction = on_f, .argument = pd.result } }),
                    .rejected => try self.enqueueJob(.{ .reaction = .{ .reaction = on_r, .argument = pd.result } }),
                }
            },
            .ret => {
                gen.state = .completed;
                if (gen.thread) |t| {
                    t.join();
                    gen.thread = null;
                }
                try self.resolvePromise(gen.promise.?, gen.transfer_value);
            },
            .throw => {
                gen.state = .completed;
                if (gen.thread) |t| {
                    t.join();
                    gen.thread = null;
                }
                // §27.7.5.2: an uncaught throw rejects the function's promise.
                const promise = gen.promise.?;
                const pd = promise.promise.?;
                if (!pd.already_resolved) {
                    pd.already_resolved = true;
                    try self.rejectPromise(promise, gen.transfer_value);
                }
            },
        }
    }

    /// The async-body thread entry (mirrors `generatorBodyThread`): a fresh per-body interpreter sharing
    /// the arena + globals + job queue, with `current_gen` set so `await` reaches the handoff. Runs the
    /// body and posts the terminal completion. Engine errors become a thrown completion.
    fn asyncBodyThread(parent: *Interpreter, gen: *object_mod.Generator) void {
        var body: Interpreter = .{
            .arena = parent.arena,
            .step_limit = parent.step_limit,
            .globals = parent.globals,
            .gen_registry = parent.gen_registry,
            .job_queue = parent.job_queue,
            .io = parent.io,
            .current_gen = gen,
        };
        const comp = body.runGeneratorBody(gen) catch |e| blk: {
            const kind: []const u8 = if (e == error.StepLimitExceeded) "RangeError" else "Error";
            const msg: []const u8 = if (e == error.StepLimitExceeded) "step limit exceeded" else "out of memory";
            const tc = body.throwError(kind, msg) catch break :blk Completion{ .throw = .undefined };
            break :blk tc;
        };
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
                gen.transfer_value = .undefined;
                gen.transfer_kind = .ret;
            },
        }
        gen.to_caller.post(body.io);
    }

    /// §27.7.5.3 the `await x` runtime — on the async body thread: hand `x` (the awaited value) out via
    /// the ping-pong handoff (`transfer_kind = .yield`, reusing `doYieldRaw`), park until the caller's
    /// reaction Job resumes us with the settlement (`.next` value → await result; `.throw` reason →
    /// throw at the await point). Only runs on an async body thread (`current_gen.is_async`).
    /// §ER Dispose step 3.a — `Await(result)` of an `await using` disposer's return value. Only an
    /// async body thread can suspend on an await; when running there (`current_gen.is_async`) we await
    /// via the normal handoff, so a thenable disposal result is adopted. Outside an async body (which
    /// `await using` should never be, but guard defensively) the value passes through unawaited.
    fn awaitDisposeResult(self: *Interpreter, value: Value) EvalError!Completion {
        const cg = self.current_gen orelse return .{ .normal = value };
        if (!cg.is_async) return .{ .normal = value };
        return self.doAwait(value);
    }

    fn doAwait(self: *Interpreter, value: Value) EvalError!Completion {
        // §27.6.3.8: in an async generator the servicer must distinguish an await from a yield (both are
        // `.yield`-kind handoffs); mark this transfer as an await so it registers resumption reactions.
        self.current_gen.?.transfer_await = true;
        const r = self.doYieldRaw(value);
        if (r.abandon) return .{ .ret = .undefined }; // realm teardown woke us to unwind
        return switch (r.kind) {
            .next => .{ .normal = r.value }, // §27.7.5.3: await evaluates to the fulfillment value
            .throw => .{ .throw = r.value }, // a rejected await throws the reason into the body
            .ret => .{ .ret = r.value }, // teardown injection (unwind, run finally blocks)
        };
    }

    // ── §27.6 Async Generators (thread substrate + Promise/Job runtime) ──────────
    //
    // An async generator body runs on the SAME std.Thread substrate as a sync generator / async
    // function. It may suspend in two ways, BOTH via `doYieldRaw` (carry a value out, park):
    //   • `await x`  → `transfer_await = true`; the servicer wraps x via PromiseResolve and registers
    //                  fulfill/reject reactions that resume the body (identical to an async fn await).
    //   • `yield x`  → AsyncGeneratorYield (§27.6.3.8): FIRST `await x` (above), THEN a second handoff
    //                  with `transfer_await = false` carrying x out; the servicer resolves the CURRENT
    //                  request's promise with {value:x, done:false}.
    // Each `.next/.return/.throw` enqueues an AsyncGenRequest (returning a fresh promise) and kicks the
    // servicing loop (`asyncGenDrainQueue`), which runs the body to its next yield/await/completion and
    // settles requests, one at a time. The terminal completion settles the front request done:true /
    // rejection. NO HANGS: every resume runs the body to exactly one suspension; the servicer registers
    // a reaction (await) or settles + dequeues (yield/terminal) and returns to the Job drain.

    /// §27.6.3.8 AsyncGeneratorYield — on the async-gen body thread: first AWAIT the operand (so a
    /// thenable yield value is adopted), then hand it out as a YIELD (`transfer_await = false`) and park
    /// until the next request resumes us. A `.next(v)` makes the yield evaluate to `v`; an injected
    /// `.throw`/`.return` re-throws / returns at the yield point (running finally blocks).
    fn doAsyncYield(self: *Interpreter, value: Value) EvalError!Completion {
        // §27.6.3.8 step 5: Await the operand first.
        const ac = try self.doAwait(value);
        if (ac.isAbrupt()) return ac; // a rejected await of the yield operand throws into the body
        const awaited = ac.normal;
        // Now suspend producing the yielded value (a non-await handoff → the servicer settles the request).
        self.current_gen.?.transfer_await = false;
        const r = self.doYieldRaw(awaited);
        if (r.abandon) return .{ .ret = .undefined };
        return switch (r.kind) {
            .next => .{ .normal = r.value }, // the value sent to the next .next(v)
            .throw => .{ .throw = r.value }, // §27.6.3.8: an injected .throw re-throws at the yield
            .ret => .{ .ret = r.value }, // an injected .return returns (runs finally blocks)
        };
    }

    /// §27.6.3.8 `yield* expr` in an ASYNC generator — delegate over the ASYNC iterator of `expr`
    /// (GetIterator async; a sync iterable is wrapped). Each round: await the inner `next/throw/return`
    /// (its result is a promise), decode `{value, done}`; a done result finishes the `yield*` with that
    /// value; otherwise re-yield the value to the outer consumer (an AsyncGeneratorYield) and forward the
    /// next resumption to the inner iterator. Runs on the async-gen body thread.
    fn doAsyncYieldDelegate(self: *Interpreter, source: Value) EvalError!Completion {
        const ait = try self.getAsyncIterator(source);
        const iterator: *Object = switch (ait) {
            .abrupt => |c| return c,
            .iterator => |it| it,
        };
        var received: Resumption = .{ .kind = .next, .value = .undefined, .abandon = false };
        while (true) {
            const method: []const u8 = switch (received.kind) {
                .next => "next",
                .throw => "throw",
                .ret => "return",
            };
            // §27.6.3.8: a `.throw`/`.return` to a missing inner method is special-cased.
            if (received.kind != .next) {
                const mc = try self.getProperty(.{ .object = iterator }, method);
                if (mc.isAbrupt()) return mc;
                if (mc.normal != .object or mc.normal.object.kind != .function) {
                    if (received.kind == .ret) return .{ .ret = received.value };
                    try self.asyncIteratorClose(iterator);
                    return self.throwError("TypeError", "The async iterator does not provide a throw method");
                }
            }
            const raw = try self.iteratorCallRaw(iterator, method, received.value, true);
            if (raw.isAbrupt()) return raw;
            // Await the (promise) result, then decode.
            const aw = try self.doAwait(raw.normal);
            if (aw.isAbrupt()) return aw;
            const decoded = try self.iterResultFromValue(aw.normal);
            const step: IterStep = switch (decoded) {
                .abrupt => |c| return c,
                .result => |r| r,
            };
            if (step.done) {
                // §27.6.3.8: a done `.return` result returns from the body; otherwise the yield* value.
                if (received.kind == .ret) return .{ .ret = step.value };
                return .{ .normal = step.value };
            }
            // Re-yield the inner value to the outer consumer (AsyncGeneratorYield), capturing the next
            // resumption (which we forward to the inner iterator).
            const yc = try self.doAsyncYield(step.value);
            switch (yc) {
                .normal => |v| received = .{ .kind = .next, .value = v, .abandon = false },
                .throw => |e| received = .{ .kind = .throw, .value = e, .abandon = false },
                .ret => |v| return .{ .ret = v }, // an injected .return unwinds the body
                .brk, .cont => return .{ .ret = .undefined },
            }
        }
    }

    /// §27.6.2 calling an `async function*` — create an AsyncGenerator object in `suspended_start`
    /// (lazy: the body thread spawns on the first request). Mirrors `createGenerator` but tags the
    /// underlying Generator `is_async`+`is_async_gen` and links it to the AsyncGenerator state.
    fn createAsyncGenerator(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        const gen = try self.arena.create(object_mod.Generator);
        const args_copy = try self.arena.dupe(Value, args);
        gen.* = .{
            .func = func,
            .args = args_copy,
            .this_val = this_val,
            .home_object = if (func.call) |fd| fd.home_object else null,
            .is_async = true,
            .is_async_gen = true,
        };
        // §15.6.2 EvaluateAsyncGeneratorBody: FunctionDeclarationInstantiation runs EAGERLY here (on the
        // caller thread). A param destructuring/default error throws synchronously at the call site —
        // the async-generator object is never created (matches V8: `ag(bad)` throws, not a rejected next).
        var abrupt: ?Completion = null;
        gen.call_env = try self.instantiateGeneratorParams(gen, &abrupt);
        if (abrupt) |c| return c;
        const ag = try self.arena.create(object_mod.AsyncGenerator);
        ag.* = .{ .gen = gen };
        gen.async_gen = ag;
        if (self.gen_registry) |reg| try reg.append(self.arena, gen);
        const obj = try Object.create(self.arena, self.asyncGeneratorProto());
        obj.async_generator = ag;
        return .{ .normal = .{ .object = obj } };
    }

    /// %AsyncGeneratorPrototype% — stashed under the sentinel global name by `builtins.setup`.
    fn asyncGeneratorProto(self: *Interpreter) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup("%AsyncGeneratorPrototype%") orelse return null;
        return if (b.value == .object) b.value.object else null;
    }

    /// %AsyncFromSyncIteratorPrototype% — the proto of an AsyncFromSyncIterator wrapper object.
    fn asyncFromSyncProto(self: *Interpreter) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup("%AsyncFromSyncIteratorPrototype%") orelse return null;
        return if (b.value == .object) b.value.object else null;
    }

    /// §27.6.1.2/.3/.4 %AsyncGeneratorPrototype%.next/return/throw — enqueue an AsyncGeneratorRequest
    /// (returning a fresh promise) and drive the queue. Each ALWAYS returns a promise (a sync error —
    /// e.g. called on a non-async-generator — rejects that promise rather than throwing, §27.6.1.2).
    fn asyncGeneratorResume(self: *Interpreter, this_val: Value, kind: object_mod.ResumeKind, value: Value) EvalError!Completion {
        const promise = try self.newPromise();
        const resolve_fn = try self.makeResolvingFunction(promise, .promise_resolve_fn);
        const reject_fn = try self.makeResolvingFunction(promise, .promise_reject_fn);
        // §27.6.1.2 step 3: a brand-check failure rejects the returned promise (does NOT throw).
        if (this_val != .object or this_val.object.async_generator == null) {
            const tc = try self.throwError("TypeError", "not an async generator");
            try self.rejectPromiseRaw(promise, tc.throw);
            return .{ .normal = .{ .object = promise } };
        }
        const ag = this_val.object.async_generator.?;
        // §27.6.3.1 AsyncGeneratorEnqueue: append the request to the queue.
        try ag.queue.append(self.arena, .{ .kind = kind, .value = value, .promise = promise, .resolve = resolve_fn, .reject = reject_fn });
        // §27.6.3.4 AsyncGeneratorDrainQueue: if not already running and not awaiting-return, service it.
        if (ag.state != .executing and ag.state != .awaiting_return) {
            try self.asyncGenDrainQueue(ag);
        }
        return .{ .normal = .{ .object = promise } };
    }

    /// §27.6.3.4 AsyncGeneratorDrainQueue / §27.6.3.5 AsyncGeneratorResume — service the FRONT request:
    /// resume the body to its next yield/await/completion (or, on a completed generator, settle the
    /// request directly), then react to the transfer. Services requests until the body suspends on an
    /// `await` (a reaction Job will re-enter via `asyncGenResumeAfterAwait`) or the queue drains. Runs on
    /// the servicing interpreter (main or a Job).
    fn asyncGenDrainQueue(self: *Interpreter, ag: *object_mod.AsyncGenerator) EvalError!void {
        while (ag.head < ag.queue.items.len) {
            const req = ag.queue.items[ag.head];
            // §27.6.3.5 on a COMPLETED async generator: settle the request without running the body.
            if (ag.state == .completed) {
                switch (req.kind) {
                    .next => try self.asyncGenSettleResult(req, .undefined, true),
                    .ret => try self.asyncGenSettleResult(req, req.value, true),
                    .throw => _ = try self.callFunction(req.reject, &.{req.value}, .undefined),
                }
                ag.head += 1;
                continue;
            }
            const gen = ag.gen;
            if (ag.state == .suspended_start) {
                // §27.6.3.5: spawn the body thread; it runs to the first await/yield/completion.
                // A `.return`/`.throw` on a suspended-start async generator completes it directly.
                if (req.kind == .ret) {
                    ag.state = .completed;
                    try self.asyncGenSettleResult(req, req.value, true);
                    ag.head += 1;
                    continue;
                }
                if (req.kind == .throw) {
                    ag.state = .completed;
                    _ = try self.callFunction(req.reject, &.{req.value}, .undefined);
                    ag.head += 1;
                    continue;
                }
                ag.state = .executing;
                gen.resume_kind = .next;
                gen.sent_value = req.value;
                gen.transfer_await = false;
                const t = std.Thread.spawn(.{}, asyncBodyThread, .{ self, gen }) catch {
                    ag.state = .completed;
                    const tc = try self.throwError("RangeError", "Cannot spawn async generator thread");
                    _ = try self.callFunction(req.reject, &.{tc.throw}, .undefined);
                    ag.head += 1;
                    continue;
                };
                gen.thread = t;
                gen.to_caller.waitUncancelable(self.io);
            } else {
                // §27.6.3.5 SUSPENDED-YIELD: resume the parked yield with the request's completion.
                ag.state = .executing;
                gen.resume_kind = req.kind;
                gen.sent_value = req.value;
                gen.transfer_await = false;
                gen.resume_gen.post(self.io);
                gen.to_caller.waitUncancelable(self.io);
            }
            // React to where the body suspended / completed.
            const more = try self.asyncGenHandleTransfer(ag);
            if (!more) return; // suspended on an await — a reaction Job will resume the drain
        }
    }

    /// After a body handoff: classify the transfer. An AWAIT suspension registers reactions that resume
    /// the body (returns false — stop draining; the Job continues it). A YIELD settles the front request
    /// with {value,done:false} and advances the queue (returns true — keep draining the next request). A
    /// terminal return/throw settles the front request done:true / rejection (returns true).
    fn asyncGenHandleTransfer(self: *Interpreter, ag: *object_mod.AsyncGenerator) EvalError!bool {
        const gen = ag.gen;
        switch (gen.transfer_kind) {
            .yield => {
                if (gen.transfer_await) {
                    // §27.6.3.8 step 8 (await): the body is parked on an await — register reactions on
                    // PromiseResolve(value) that resume THIS body (via `asyncGenResumeAfterAwait`). Keep
                    // `ag.state = .executing` so a NEW request arriving in this window only ENQUEUES (the
                    // resume-guard in `asyncGeneratorResume` skips draining while executing) and does NOT
                    // post `resume_gen` — the body is waiting for the await reaction, not a request. The
                    // sole resume path is the reaction Job. (`gen.state` is left for `cleanupGenerators`.)
                    ag.state = .executing;
                    gen.state = .suspended_yield; // mark the body thread parked (for realm teardown).
                    const awaited = try self.promiseResolveValue(gen.transfer_value);
                    const on_f: object_mod.PromiseReaction = .{ .kind = .fulfill, .handler = null, .capability = null, .await_gen = gen };
                    const on_r: object_mod.PromiseReaction = .{ .kind = .reject, .handler = null, .capability = null, .await_gen = gen };
                    const pd = awaited.promise.?;
                    switch (pd.state) {
                        .pending => {
                            try pd.fulfill_reactions.append(self.arena, on_f);
                            try pd.reject_reactions.append(self.arena, on_r);
                        },
                        .fulfilled => try self.enqueueJob(.{ .reaction = .{ .reaction = on_f, .argument = pd.result } }),
                        .rejected => try self.enqueueJob(.{ .reaction = .{ .reaction = on_r, .argument = pd.result } }),
                    }
                    return false;
                }
                // §27.6.3.8 a real YIELD: settle the front request with {value, done:false}, advance.
                ag.state = .suspended_yield;
                gen.state = .suspended_yield; // the body thread is parked at the yield (for teardown).
                const req = ag.queue.items[ag.head];
                try self.asyncGenSettleResult(req, gen.transfer_value, false);
                ag.head += 1;
                return true;
            },
            .ret => {
                // §27.6.3.5: body returned — settle the front request {value, done:true}, complete.
                ag.state = .completed;
                if (gen.thread) |t| {
                    t.join();
                    gen.thread = null;
                }
                const req = ag.queue.items[ag.head];
                try self.asyncGenSettleResult(req, gen.transfer_value, true);
                ag.head += 1;
                return true;
            },
            .throw => {
                // §27.6.3.5: an uncaught throw — reject the front request, complete the generator.
                ag.state = .completed;
                if (gen.thread) |t| {
                    t.join();
                    gen.thread = null;
                }
                const req = ag.queue.items[ag.head];
                _ = try self.callFunction(req.reject, &.{gen.transfer_value}, .undefined);
                ag.head += 1;
                return true;
            },
        }
    }

    /// Resume an async-generator body parked on an `await` (called from a settled-await reaction Job),
    /// run it to the next suspension/completion, react, and keep draining the queue. `.next` → the await
    /// evaluates to `value`; `.throw` → the await throws `value`.
    fn asyncGenResumeAfterAwait(self: *Interpreter, gen: *object_mod.Generator, kind: object_mod.ResumeKind, value: Value) EvalError!void {
        const ag = gen.async_gen.?;
        if (ag.state == .completed) return; // defensive
        ag.state = .executing;
        gen.resume_kind = kind;
        gen.sent_value = value;
        gen.transfer_await = false;
        gen.resume_gen.post(self.io);
        gen.to_caller.waitUncancelable(self.io);
        const more = try self.asyncGenHandleTransfer(ag);
        if (more) try self.asyncGenDrainQueue(ag);
    }

    /// Settle a request's promise with a CreateIterResultObject {value, done} (§7.4.1) via its resolve
    /// function (so a thenable value is properly adopted, §27.6.3.9 step 9 uses the resolve abstraction).
    fn asyncGenSettleResult(self: *Interpreter, req: object_mod.AsyncGenRequest, value: Value, done: bool) EvalError!void {
        const result = try self.iterResultObject(value, done);
        _ = try self.callFunction(req.resolve, &.{.{ .object = result }}, .undefined);
    }

    /// Build a plain IteratorResult `{ value, done }` object (proto %Object.prototype%). Like
    /// `iterResult` but returns the bare Object (callers wrap into a Completion / pass to resolve).
    fn iterResultObject(self: *Interpreter, value: Value, done: bool) EvalError!*Object {
        const obj = try Object.create(self.arena, self.objectProto());
        try obj.set("value", value);
        try obj.set("done", .{ .boolean = done });
        return obj;
    }

    // ── §27.1.4 AsyncFromSyncIterator ────────────────────────────────────────────

    /// §27.1.4.2.1/.2/.3 %AsyncFromSyncIteratorPrototype%.next/return/throw — drive the wrapped SYNC
    /// iterator's matching method and return a PROMISE of the IteratorResult whose `value` has been
    /// awaited (§27.1.4.4 AsyncFromSyncIteratorContinuation). A sync throw rejects the returned promise.
    /// `return`/`throw` on a sync iterator lacking that method resolve/reject per §27.1.4.2.2/.3 step 5.
    fn asyncFromSyncMethod(self: *Interpreter, name: []const u8, this_val: Value, arg: Value, has_arg: bool) EvalError!Completion {
        const promise = try self.newPromise();
        if (this_val != .object or this_val.object.async_from_sync == null) {
            const tc = try self.throwError("TypeError", "not an AsyncFromSyncIterator");
            try self.rejectPromiseRaw(promise, tc.throw);
            return .{ .normal = .{ .object = promise } };
        }
        const sync_iter = this_val.object.async_from_sync.?;
        const is_next = std.mem.eql(u8, name, "next");
        const is_return = std.mem.eql(u8, name, "return");
        // §27.1.4.2.2/.3 step 3: look up `return`/`throw` on the sync iterator; absent → special-case.
        if (!is_next) {
            const mc = try self.getProperty(.{ .object = sync_iter }, name);
            if (mc.isAbrupt()) {
                try self.rejectPromiseRaw(promise, mc.throw);
                return .{ .normal = .{ .object = promise } };
            }
            if (mc.normal != .object or mc.normal.object.kind != .function) {
                // §27.1.4.2.2 step 5: absent `return` → resolve with { value: arg, done: true }.
                // §27.1.4.2.3 step 5: absent `throw` → reject with `arg` (re-throw the exception).
                if (is_return) {
                    const ir = try self.iterResultObject(if (has_arg) arg else .undefined, true);
                    try self.resolvePromise(promise, .{ .object = ir });
                } else {
                    try self.rejectPromiseRaw(promise, arg);
                }
                return .{ .normal = .{ .object = promise } };
            }
        }
        // Call the sync iterator's method, decode the IteratorResult.
        const raw = try self.iteratorCallRaw(sync_iter, name, arg, has_arg);
        if (raw.isAbrupt()) {
            try self.rejectPromiseRaw(promise, raw.throw);
            return .{ .normal = .{ .object = promise } };
        }
        const decoded = try self.iterResultFromValue(raw.normal);
        const step: IterStep = switch (decoded) {
            .abrupt => |c| {
                try self.rejectPromiseRaw(promise, c.throw);
                return .{ .normal = .{ .object = promise } };
            },
            .result => |r| r,
        };
        // §27.1.4.4 AsyncFromSyncIteratorContinuation: valueWrapper = PromiseResolve(value); the result
        // promise resolves, when valueWrapper settles, to CreateIterResultObject(awaitedValue, done).
        const value_wrapper = try self.promiseResolveValue(step.value);
        const wrap = try Object.createNative(self.arena, .async_from_sync_wrap, "");
        wrap.prototype = self.functionProto();
        wrap.afs_done = step.done;
        // PerformPromiseThen(valueWrapper, wrap) with the result promise as the capability.
        try self.performPromiseThen(value_wrapper, wrap, null, promise);
        return .{ .normal = .{ .object = promise } };
    }

    /// §27.2.3.1 the Promise constructor — `new Promise(executor)`: create a pending promise, build its
    /// resolve/reject functions, call `executor(resolve, reject)`, and reject the promise if the
    /// executor throws (§27.2.3.1 step 9–10). `executor` must be callable (§27.2.3.1 step 2 TypeError).
    fn promiseConstructor(self: *Interpreter, args: []const Value) EvalError!Completion {
        const executor: Value = if (args.len > 0) args[0] else .undefined;
        if (executor != .object or !isCallable(executor.object)) {
            return self.throwError("TypeError", "Promise resolver is not a function");
        }
        const promise = try self.newPromise();
        const resolve_fn = try self.makeResolvingFunction(promise, .promise_resolve_fn);
        const reject_fn = try self.makeResolvingFunction(promise, .promise_reject_fn);
        const rc = try self.callFunction(executor.object, &.{ .{ .object = resolve_fn }, .{ .object = reject_fn } }, .undefined);
        if (rc == .throw) {
            // §27.2.3.1 step 10: an executor that throws rejects the promise (unless already resolved).
            const pd = promise.promise.?;
            if (!pd.already_resolved) {
                pd.already_resolved = true;
                try self.rejectPromise(promise, rc.throw);
            }
        }
        return .{ .normal = .{ .object = promise } };
    }

    /// §27.2.4.5 Promise.resolve(x) / §27.2.4.4 Promise.reject(r) — the `this`-static factories. resolve
    /// returns `x` unchanged if it is already a promise, else a promise resolved with `x`; reject always
    /// makes a fresh rejected promise.
    fn promiseStaticResolve(self: *Interpreter, args: []const Value) EvalError!Completion {
        const x: Value = if (args.len > 0) args[0] else .undefined;
        const p = try self.promiseResolveValue(x);
        return .{ .normal = .{ .object = p } };
    }
    fn promiseStaticReject(self: *Interpreter, args: []const Value) EvalError!Completion {
        const r: Value = if (args.len > 0) args[0] else .undefined;
        const p = try self.newPromise();
        try self.rejectPromiseRaw(p, r);
        return .{ .normal = .{ .object = p } };
    }

    // ── §27.2.4 Promise combinators (all / allSettled / any / race) ──────────────
    //
    // Each reads the iterable up front via §7.4 GetIterator+drain (`iterateToList`), wraps each element
    // with PromiseResolve, and registers reactions through the existing Job machinery (`performPromiseThen`).
    // `all`/`allSettled`/`any` share `CombinatorState` (a result array + a [[Remaining]] counter started
    // at 1 and decremented once per settled element + once after the loop, §27.2.4.1.1, so the empty-input
    // case settles synchronously after the loop). `race` needs no shared state — it forwards each element's
    // settlement straight to the result promise (first-settled wins; later settlements are no-ops).

    const CombinatorKind = enum { all, all_settled, any, race };

    /// §27.2.4.1/.2/.3/.6 the shared driver. A non-iterable argument rejects the result promise (the
    /// spec returns `IfAbruptRejectPromise` — a rejected promise, not a sync throw).
    fn promiseCombinator(self: *Interpreter, args: []const Value, comptime kind: CombinatorKind) EvalError!Completion {
        const result = try self.newPromise();
        const arg: Value = if (args.len > 0) args[0] else .undefined;
        // §7.4 GetIterator + drain the iterable to a value list; a non-iterable (or a throwing
        // iterator) rejects the result promise rather than throwing synchronously.
        var items: std.ArrayListUnmanaged(Value) = .empty;
        const ic = try self.iterateToList(arg, &items);
        if (ic.isAbrupt()) {
            try self.rejectPromiseRaw(result, ic.throw);
            return .{ .normal = .{ .object = result } };
        }

        if (kind == .race) {
            // §27.2.4.6.1 PerformPromiseRace — forward each element's settlement to the result promise.
            // The first to settle wins (`resolvePromise`/`rejectPromiseRaw` honor [[AlreadyResolved]]).
            for (items.items) |item| {
                const ep = try self.promiseResolveValue(item);
                try self.performPromiseThen(ep, try self.makeResolvingFunction(result, .promise_resolve_fn), try self.makeResolvingFunction(result, .promise_reject_fn), null);
            }
            return .{ .normal = .{ .object = result } };
        }

        const state = try self.arena.create(object_mod.CombinatorState);
        state.* = .{ .capability = result };
        for (items.items, 0..) |item, index| {
            // §27.2.4.1.1 step d.iii: a placeholder slot per element (filled by its resolve closure).
            try state.values.append(self.arena, .undefined);
            state.remaining += 1;
            const ep = try self.promiseResolveValue(item);
            const on_f = try self.makeCombinatorElement(state, index, switch (kind) {
                .all => "all",
                .all_settled => "settled_fulfill",
                .any => "any_fulfill",
                .race => unreachable,
            });
            const on_r: ?*Object = switch (kind) {
                // §27.2.4.1: `all` reject → reject the result promise directly (the default reject closure).
                .all => try self.makeResolvingFunction(result, .promise_reject_fn),
                // §27.2.4.2/.3: `allSettled` reject and `any` reject record into the shared state.
                .all_settled => try self.makeCombinatorElement(state, index, "settled_reject"),
                .any => try self.makeCombinatorElement(state, index, "any_reject"),
                .race => unreachable,
            };
            try self.performPromiseThen(ep, on_f, on_r, null);
        }
        // §27.2.4.1.1 step e: the implicit final decrement — if every element already settled (or there
        // were none), settle the result now.
        try self.combinatorSettleIfDone(state, kind);
        return .{ .normal = .{ .object = result } };
    }

    /// Build one combinator per-element resolve/reject closure (id `promise_combinator_element`),
    /// carrying the shared `state` and this element's `index`. `variant` selects the behavior.
    fn makeCombinatorElement(self: *Interpreter, state: *object_mod.CombinatorState, index: usize, variant: []const u8) EvalError!*Object {
        const f = try Object.createNative(self.arena, .promise_combinator_element, variant);
        f.prototype = self.functionProto();
        f.combinator = state;
        f.combinator_index = index;
        return f;
    }

    /// The body of a `promise_combinator_element` closure (§27.2.4.1.2 / .2.2 / .3.2). Records this
    /// element's settlement into the shared state, then settles the result if it was the last one.
    /// `[[AlreadyCalled]]` makes each closure fire at most once.
    fn promiseCombinatorElement(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
        const state = func.combinator orelse return .{ .normal = .undefined };
        if (func.already_called) return .{ .normal = .undefined }; // §27.2.4.1.2 step 2–4 [[AlreadyCalled]]
        func.already_called = true;
        const arg: Value = if (args.len > 0) args[0] else .undefined;
        const index = func.combinator_index;
        // NOTE: `combinatorSettleIfDone` is the SOLE place that decrements [[Remaining]] (per call) — the
        // element body only records its slot, then asks to settle. This avoids a double decrement.
        if (std.mem.eql(u8, func.native_name, "all")) {
            // §27.2.4.1.2: record the fulfillment value; reject is the result promise's reject closure.
            state.values.items[index] = arg;
            try self.combinatorSettleIfDone(state, .all);
        } else if (std.mem.eql(u8, func.native_name, "any_reject")) {
            // §27.2.4.3.2: record the rejection reason; if ALL reject, fail with an AggregateError.
            state.values.items[index] = arg;
            try self.combinatorSettleIfDone(state, .any);
        } else if (std.mem.eql(u8, func.native_name, "any_fulfill")) {
            // §27.2.4.3.1 step 8.j: the FIRST fulfillment resolves `any`'s result (later ones are no-ops).
            try self.resolvePromise(state.capability, arg);
        } else {
            // §27.2.4.2.2/.3 allSettled — build the `{status, value|reason}` record either way.
            const rec = try Object.create(self.arena, self.objectProto());
            if (std.mem.eql(u8, func.native_name, "settled_fulfill")) {
                try rec.set("status", .{ .string = "fulfilled" });
                try rec.set("value", arg);
            } else {
                try rec.set("status", .{ .string = "rejected" });
                try rec.set("reason", arg);
            }
            state.values.items[index] = .{ .object = rec };
            try self.combinatorSettleIfDone(state, .all_settled);
        }
        return .{ .normal = .undefined };
    }

    /// §27.2.4.1.1 settle the combinator's result once [[Remaining]] reaches 0. `all`/`allSettled`
    /// fulfill with the values array; `any` rejects with an AggregateError of the collected reasons.
    fn combinatorSettleIfDone(self: *Interpreter, state: *object_mod.CombinatorState, comptime kind: CombinatorKind) EvalError!void {
        state.remaining -= 1;
        if (state.remaining != 0) return;
        switch (kind) {
            .all, .all_settled => {
                const arr = try Object.createArray(self.arena, self.arrayProto());
                try arr.elements.appendSlice(self.arena, state.values.items);
                try self.resolvePromise(state.capability, .{ .object = arr });
            },
            .any => {
                // §27.2.4.3.1 step 8.d.iii / .3.2: every input rejected → reject with an AggregateError
                // whose `errors` is the array of reasons.
                const errs = try Object.createArray(self.arena, self.arrayProto());
                try errs.elements.appendSlice(self.arena, state.values.items);
                const agg = try self.makeAggregateError(.{ .object = errs }, "All promises were rejected");
                try self.rejectPromiseRaw(state.capability, agg);
            },
            .race => unreachable,
        }
    }

    /// §20.5.7.1 build an AggregateError object with `errors` (an array) and `message`, proto-linked to
    /// %AggregateError.prototype%. Used by `Promise.any` when every input rejects.
    fn makeAggregateError(self: *Interpreter, errors: Value, message: []const u8) EvalError!Value {
        const proto = self.globalProto("AggregateError") orelse self.errorProto("Error");
        const err = try Object.create(self.arena, proto);
        try err.set("name", .{ .string = "AggregateError" });
        try err.set("message", .{ .string = message });
        try err.defineData("errors", errors, true, false, true); // §20.5.7.4 own data property
        return .{ .object = err };
    }

    /// §27.2.5.4 Promise.prototype.then(onFulfilled, onRejected) — `this` must be a promise; attach the
    /// (callable-or-ignored) handlers and return the derived result promise.
    fn promiseThen(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
        if (this_val != .object or this_val.object.promise == null) {
            return self.throwError("TypeError", "Promise.prototype.then called on a non-Promise");
        }
        const on_f = handlerArg(args, 0);
        const on_r = handlerArg(args, 1);
        const result = try self.newPromise();
        try self.performPromiseThen(this_val.object, on_f, on_r, result);
        return .{ .normal = .{ .object = result } };
    }

    /// §27.2.5.1 Promise.prototype.catch(onRejected) — `this.then(undefined, onRejected)`.
    fn promiseCatch(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
        const on_r = handlerArg(args, 0);
        if (this_val != .object or this_val.object.promise == null) {
            return self.throwError("TypeError", "Promise.prototype.catch called on a non-Promise");
        }
        const result = try self.newPromise();
        try self.performPromiseThen(this_val.object, null, on_r, result);
        return .{ .normal = .{ .object = result } };
    }

    /// §27.2.5.3 Promise.prototype.finally(onFinally) — `this.then(thunk, thrower)` where the thunks run
    /// `onFinally()` and then pass through the original value / re-throw the reason. If `onFinally` is
    /// not callable, both handlers are it (so `then` treats them as the default pass-through).
    fn promiseFinally(self: *Interpreter, this_val: Value, args: []const Value) EvalError!Completion {
        if (this_val != .object or this_val.object.promise == null) {
            return self.throwError("TypeError", "Promise.prototype.finally called on a non-Promise");
        }
        const on_finally: Value = if (args.len > 0) args[0] else .undefined;
        const result = try self.newPromise();
        if (on_finally != .object or !isCallable(on_finally.object)) {
            // §27.2.5.3 step 6/8: a non-callable onFinally → both reactions are the default pass-through.
            try self.performPromiseThen(this_val.object, null, null, result);
            return .{ .normal = .{ .object = result } };
        }
        // §27.2.5.3.1/.2 the thunks: each captures onFinally; the value-thunk re-fulfills with the
        // original value after onFinally(), the thrower-thunk re-throws the reason.
        const value_thunk = try Object.createNative(self.arena, .promise_finally_thunk, "value");
        value_thunk.prototype = self.functionProto();
        value_thunk.finally_value = on_finally.object;
        const thrower_thunk = try Object.createNative(self.arena, .promise_finally_thunk, "thrower");
        thrower_thunk.prototype = self.functionProto();
        thrower_thunk.finally_value = on_finally.object;
        try self.performPromiseThen(this_val.object, value_thunk, thrower_thunk, result);
        return .{ .normal = .{ .object = result } };
    }

    /// The finally value/thrower thunk body (§27.2.5.3.1/.2): call the captured onFinally(); on the
    /// "value" thunk return the original argument (after awaiting onFinally is M-subset-simplified to a
    /// synchronous call — onFinally's own promise is not awaited here); on "thrower" re-throw `arg`.
    fn promiseFinallyThunk(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
        const arg: Value = if (args.len > 0) args[0] else .undefined;
        const on_finally = func.finally_value orelse return .{ .normal = arg };
        const fc = try self.callFunction(on_finally, &.{}, .undefined);
        if (fc == .throw) return fc; // onFinally threw → propagate (rejects the derived promise)
        if (std.mem.eql(u8, func.native_name, "thrower")) return .{ .throw = arg };
        return .{ .normal = arg };
    }

    /// The resolve/reject function bodies (§27.2.1.3.2 / §27.2.1.3.1) — settle the captured
    /// `promise_slot` with the argument. resolve → ResolvePromise (thenable-aware); reject → RejectPromise.
    fn promiseResolvingFn(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
        const promise = func.promise_slot orelse return .{ .normal = .undefined };
        const arg: Value = if (args.len > 0) args[0] else .undefined;
        if (func.native == .promise_resolve_fn) {
            try self.resolvePromise(promise, arg);
        } else {
            try self.resolvePromiseReject(promise, arg);
        }
        return .{ .normal = .undefined };
    }

    /// Runner-injected `$DONE(err)` (Test262 asyncHelpers.js / doneprintHandle.js contract): record the
    /// async test's completion. No/undefined/falsy arg → async PASS; a truthy arg → async FAIL (with the
    /// argument stringified for diagnostics). Only the FIRST call counts (a re-`$DONE` is ignored, per
    /// the harness). Writes the shared `async_done` sink the runner reads after draining the Job queue.
    fn testDone(self: *Interpreter, args: []const Value) EvalError!Completion {
        const sink = self.async_done orelse return .{ .normal = .undefined };
        if (sink.called) return .{ .normal = .undefined }; // idempotent: first $DONE wins
        sink.called = true;
        const arg: Value = if (args.len > 0) args[0] else .undefined;
        if (arg != .undefined and toBoolean(arg)) {
            sink.failed = true;
            sink.message = self.toString(arg) catch "async test failed";
        }
        return .{ .normal = .undefined };
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
        // §13.5.7 `!` and §13.5.2 `void` need no numeric coercion (so no ToPrimitive side effect).
        switch (op) {
            .not => return .{ .normal = .{ .boolean = !toBoolean(v) } }, // §13.5.7
            .void_ => return .{ .normal = .undefined }, // §13.5.2: evaluate operand (done), yield undefined
            .typeof_, .delete_ => unreachable,
            else => {},
        }
        // §13.5.4/.5/.6: unary `+`/`-`/`~` ToPrimitive (number hint), then operate. A BigInt primitive
        // takes the BigInt path: `-`/`~` produce a BigInt; unary `+` on a BigInt is a TypeError (§13.5.4.1).
        const pc = try self.toPrimitive(v, .number);
        if (pc.isAbrupt()) return pc;
        const prim = pc.normal;
        if (prim == .bigint) {
            const b = prim.bigint;
            switch (op) {
                .plus => return self.throwError("TypeError", "Cannot convert a BigInt value to a number"), // §13.5.4.1
                .minus => return .{ .normal = .{ .bigint = bigint.neg(self.arena, b) catch |e| return self.bigintError(e) } }, // §13.5.5
                .bit_not => return .{ .normal = .{ .bigint = bigint.bitNot(self.arena, b) catch |e| return self.bigintError(e) } }, // §13.5.6
                else => unreachable,
            }
        }
        if (prim == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        const n = toNumber(prim);
        return switch (op) {
            .plus => .{ .normal = .{ .number = n } }, // §13.5.4
            .minus => .{ .normal = .{ .number = -n } }, // §13.5.5
            .bit_not => .{ .normal = .{ .number = @floatFromInt(~numToInt32(n)) } }, // §13.5.6
            else => unreachable,
        };
    }

    /// §13.5.1.2 Runtime Semantics of the `delete` UnaryExpression. `delete a.b` / `delete a[k]`
    /// resolves the base object, removes the own property `key`, and returns `true`. For an array
    /// integer index we leave a hole by setting the element to `undefined` (M-subset; a true sparse
    /// array model is deferred). A non-Reference operand evaluates for side effects and returns true.
    /// §13.5.1.2 step 6: in strict mode a `delete` of a property reference whose [[Delete]] returned
    /// false (a non-configurable own property) is a TypeError; sloppy mode yields the `false`.
    fn finishStrictDelete(self: *Interpreter, dc: Completion) EvalError!Completion {
        if (dc.isAbrupt()) return dc;
        if (self.strict and dc.normal == .boolean and !dc.normal.boolean) return self.throwError("TypeError", "Cannot delete property of an object in strict mode");
        return dc;
    }

    fn evalDelete(self: *Interpreter, operand: *const ast.Node, env: *Environment) EvalError!Completion {
        switch (operand.*) {
            .member => |m| {
                const oc = try self.evalExpr(m.object, env);
                if (oc.isAbrupt()) return oc;
                const dc = try self.deleteProperty(oc.normal, m.name);
                return self.finishStrictDelete(dc);
            },
            .index => |ix| {
                const oc = try self.evalExpr(ix.object, env);
                if (oc.isAbrupt()) return oc;
                const kc = try self.evalExpr(ix.key, env);
                if (kc.isAbrupt()) return kc;
                // §13.5.1.2 / §10.1.10: ToPropertyKey first — a Symbol key deletes from the symbol-keyed
                // own store (`toString` would stringify it and silently no-op, leaving the prop in place).
                const pk = try self.toPropertyKey(kc.normal);
                if (pk.isAbrupt()) return pk.completion;
                if (pk.symbol) |sym| {
                    if (oc.normal == .object) return self.finishStrictDelete(.{ .normal = .{ .boolean = oc.normal.object.deleteSymbol(sym) } });
                    if (oc.normal == .undefined or oc.normal == .null) return self.throwError("TypeError", "Cannot convert undefined or null to object");
                    return .{ .normal = .{ .boolean = true } };
                }
                return self.finishStrictDelete(try self.deleteProperty(oc.normal, pk.key));
            },
            // §13.5.1.2 step 3 / §9.1.1.4.18 DeleteBinding: `delete` of an unqualified
            // IdentifierReference. A binding created by a sloppy assignment to an unresolved name
            // (§9.1.1.4.16) is a CONFIGURABLE global property — `delete` removes it (from both the
            // reified global object and the global Environment, keeping the two views consistent), so a
            // later read throws ReferenceError. Lexical/var/function bindings are non-deletable: those
            // (no configurable global-object property) keep the M-subset deviation of returning true
            // without removing. Strict `delete x` is a §13.5.1.1 SyntaxError (parse-rejected upstream).
            .identifier => |name| {
                if (self.globals) |g| {
                    if (g.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
                        const o = gb.value.object;
                        if (o.properties.get(name)) |pv| {
                            if (!pv.configurable) return .{ .normal = .{ .boolean = false } };
                            _ = o.properties.orderedRemove(name);
                            _ = g.vars.remove(name); // remove the mirrored global Environment binding
                        }
                    };
                }
                return .{ .normal = .{ .boolean = true } };
            },
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
    pub fn deleteProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        switch (base) {
            .object => |o| {
                if (o.kind == .array) {
                    if (parseIndex(key)) |i| {
                        // §10.4.2.1: delete an index → a true hole (dense slot recorded in `holes`,
                        // sparse entry removed). The slot reads `undefined` and is absent thereafter.
                        try o.arrayDelete(i);
                        // Drop any stale string-keyed entry for this index left by a generic
                        // `Object.defineProperty(arr, i, …)` so the index is no longer an own property.
                        if (o.properties.count() != 0) _ = o.properties.orderedRemove(key);
                        return .{ .normal = .{ .boolean = true } };
                    }
                }
                if (o.properties.get(key)) |pv| {
                    if (!pv.configurable) return .{ .normal = .{ .boolean = false } }; // §10.1.10.1 step 4
                    _ = o.properties.orderedRemove(key); // ordered delete preserves the remaining keys' order
                    // §10.4.4.4: deleting a MAPPED arguments index also removes it from the [[ParameterMap]],
                    // so a later read no longer aliases the (still-live) parameter binding.
                    if (o.mapped_params) |mp| {
                        if (parseIndex(key)) |i| if (i < mp.names.len) {
                            mp.names[i] = "";
                        };
                    }
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
            .add, .sub, .mul, .div, .mod, .exp, .bit_and, .bit_or, .bit_xor, .shl, .shr, .shr_un =>
            // §13.15.3 the string-or-numeric / numeric binary operators — shared with compound
            // assignment (`+=`, `*=`, …) via `applyNumericOrStringOp`.
            return self.applyNumericOrStringOp(op, l, r),
            .in_op => { // §13.10.2 `key in obj`
                if (r != .object) return self.throwError("TypeError", "Cannot use 'in' operator to search in a non-object");
                const key = try self.toString(l);
                const o = r.object;
                const has = blk: {
                    if (o.kind == .array) {
                        if (std.mem.eql(u8, key, "length")) break :blk true;
                        if (parseIndex(key)) |i| break :blk o.arrayHas(i);
                    }
                    break :blk o.get(key) != null;
                };
                return .{ .normal = .{ .boolean = has } };
            },
            .lt => return self.relationalV(l, r, .lt),
            .gt => return self.relationalV(l, r, .gt),
            .le => return self.relationalV(l, r, .le),
            .ge => return self.relationalV(l, r, .ge),
            .instanceof_ => return .{ .normal = .{ .boolean = instanceOf(l, r) } },
            .eq => {
                const c = try self.looseEqualsV(l, r);
                if (c.isAbrupt()) return c;
                return .{ .normal = .{ .boolean = c.normal.boolean } };
            },
            .ne => {
                const c = try self.looseEqualsV(l, r);
                if (c.isAbrupt()) return c;
                return .{ .normal = .{ .boolean = !c.normal.boolean } };
            },
            .seq => return .{ .normal = .{ .boolean = strictEquals(l, r) } },
            .sne => return .{ .normal = .{ .boolean = !strictEquals(l, r) } },
        }
    }

    /// §13.15.3 ApplyStringOrNumericBinaryOperator for the value-level operators shared by binary
    /// expressions and compound assignment (`+ - * / % ** & | ^ << >> >>>`). `+` is string-or-numeric
    /// (ToPrimitive default, concat if either is a String); the rest are purely numeric.
    fn applyNumericOrStringOp(self: *Interpreter, op: ast.BinaryOp, l: Value, r: Value) EvalError!Completion {
        if (op == .add) {
            // §13.15.3: ToPrimitive(default) both operands (left then right), then concat if either is a
            // String, else numeric. An object's @@toPrimitive/valueOf/toString runs here.
            const lpc = try self.toPrimitive(l, .default);
            if (lpc.isAbrupt()) return lpc;
            const rpc = try self.toPrimitive(r, .default);
            if (rpc.isAbrupt()) return rpc;
            const lp = lpc.normal;
            const rp = rpc.normal;
            if (lp == .string or rp == .string) {
                if (lp == .symbol or rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a string");
                const ls = try self.toString(lp);
                const rs = try self.toString(rp);
                return .{ .normal = .{ .string = try std.mem.concat(self.arena, u8, &.{ ls, rs }) } };
            }
            if (lp == .bigint or rp == .bigint) return self.bigintBinary(lp, rp, .add);
            if (lp == .symbol or rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
            return .{ .normal = .{ .number = toNumber(lp) + toNumber(rp) } };
        }
        return self.numericBinary(l, r, op);
    }

    /// §13.15.3 ApplyStringOrNumericBinaryOperator for the purely numeric operators (everything but
    /// `+`): ToNumber (via ToPrimitive number-hint) both operands left-to-right, then the IEEE-754 /
    /// Int32 / UInt32 operation. A Symbol operand → TypeError (raised by `toNumberV`).
    fn numericBinary(self: *Interpreter, l: Value, r: Value, op: ast.BinaryOp) EvalError!Completion {
        // §13.15.3 / §7.1.3 ToNumeric: process the operands STRICTLY in order — ToNumeric(lhs) fully
        // (ToPrimitive + the Symbol→TypeError check) BEFORE ToNumeric(rhs) begins, so the side-effect
        // ordering matches the spec (a Symbol lhs throws before rhs's valueOf runs). A BigInt primitive
        // is left as-is for the operator step (which enforces the no-mixing TypeError).
        const lpc = try self.toPrimitive(l, .number);
        if (lpc.isAbrupt()) return lpc;
        const lp = lpc.normal;
        if (lp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        const rpc = try self.toPrimitive(r, .number);
        if (rpc.isAbrupt()) return rpc;
        const rp = rpc.normal;
        if (rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        if (lp == .bigint or rp == .bigint) return self.bigintBinary(lp, rp, op);
        const a = toNumber(lp);
        const b = toNumber(rp);
        return switch (op) {
            .sub => .{ .normal = .{ .number = a - b } },
            .mul => .{ .normal = .{ .number = a * b } },
            .div => .{ .normal = .{ .number = a / b } },
            .mod => .{ .normal = .{ .number = @rem(a, b) } },
            .exp => .{ .normal = .{ .number = std.math.pow(f64, a, b) } }, // §13.6
            .bit_and => .{ .normal = .{ .number = @floatFromInt(numToInt32(a) & numToInt32(b)) } }, // §13.12
            .bit_or => .{ .normal = .{ .number = @floatFromInt(numToInt32(a) | numToInt32(b)) } },
            .bit_xor => .{ .normal = .{ .number = @floatFromInt(numToInt32(a) ^ numToInt32(b)) } },
            .shl => blk: { // §13.9 — wrap via u32, result is int32
                const sh: u5 = @intCast(numToUint32(b) & 31);
                const res: i32 = @bitCast(numToUint32(a) << sh);
                break :blk .{ .normal = .{ .number = @floatFromInt(res) } };
            },
            .shr => blk: { // arithmetic (sign-propagating)
                const sh: u5 = @intCast(numToUint32(b) & 31);
                break :blk .{ .normal = .{ .number = @floatFromInt(numToInt32(a) >> sh) } };
            },
            .shr_un => blk: { // logical (zero-fill), result is uint32
                const sh: u5 = @intCast(numToUint32(b) & 31);
                break :blk .{ .normal = .{ .number = @floatFromInt(numToUint32(a) >> sh) } };
            },
            else => unreachable,
        };
    }

    /// §13.15.3 / §6.1.6.2 — the binary operators with at least one BigInt primitive operand. Both
    /// MUST be BigInt (mixing a BigInt with a Number/String/etc. in an arithmetic or bitwise op is a
    /// TypeError); `>>>` (UnsignedRightShift) is itself a TypeError for BigInt. Maps each op to the
    /// `bigint` module and turns its error tags into the matching JS exception.
    fn bigintBinary(self: *Interpreter, l: Value, r: Value, op: ast.BinaryOp) EvalError!Completion {
        if (op == .shr_un) return self.throwError("TypeError", "BigInts have no unsigned right shift, use >> instead");
        if (l != .bigint or r != .bigint) {
            return self.throwError("TypeError", "Cannot mix BigInt and other types, use explicit conversions");
        }
        const a = l.bigint;
        const b = r.bigint;
        const res = switch (op) {
            .add => bigint.add(self.arena, a, b),
            .sub => bigint.sub(self.arena, a, b),
            .mul => bigint.mul(self.arena, a, b),
            .div => bigint.div(self.arena, a, b),
            .mod => bigint.rem(self.arena, a, b),
            .exp => bigint.pow(self.arena, a, b),
            .bit_and => bigint.bitAnd(self.arena, a, b),
            .bit_or => bigint.bitOr(self.arena, a, b),
            .bit_xor => bigint.bitXor(self.arena, a, b),
            .shl => bigint.shl(self.arena, a, b),
            .shr => bigint.shr(self.arena, a, b),
            else => unreachable,
        } catch |e| return self.bigintError(e);
        return .{ .normal = .{ .bigint = res } };
    }

    /// Map a `bigint.Error` to the right JS exception (or propagate OutOfMemory).
    pub fn bigintError(self: *Interpreter, e: bigint.Error) EvalError!Completion {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.DivisionByZero => self.throwError("RangeError", "Division by zero"),
            error.NegativeExponent => self.throwError("RangeError", "Exponent must be non-negative"),
            error.ShiftRange => self.throwError("RangeError", "BigInt is too large"),
            error.NotAnInteger => self.throwError("RangeError", "The number is not a safe integer"),
            error.InvalidString => self.throwError("SyntaxError", "Cannot convert string to a BigInt"),
        };
    }

    /// §7.2.13 IsLessThan / §13.10 relational comparison with object coercion: ToPrimitive(number) each
    /// operand (left first), then the pure comparison (string-vs-string is lexical, else numeric).
    fn relationalV(self: *Interpreter, l: Value, r: Value, op: ops.RelOp) EvalError!Completion {
        // §13.10.1: in `a < b` LeftFirst, ToPrimitive(a) THEN ToPrimitive(b). (`numToPrimNumber`
        // is a no-op on primitives, so the common number/string case keeps its fast path.)
        const lpc = try self.toPrimitive(l, .number);
        if (lpc.isAbrupt()) return lpc;
        const rpc = try self.toPrimitive(r, .number);
        if (rpc.isAbrupt()) return rpc;
        const lp = lpc.normal;
        const rp = rpc.normal;
        // §7.2.13: a Symbol primitive operand → ToNumber throws (unless both are strings, handled in `relational`).
        if (!(lp == .string and rp == .string)) {
            if (lp == .symbol or rp == .symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        }
        return .{ .normal = .{ .boolean = relational(lp, rp, op) } };
    }

    /// §7.2.15 IsLooselyEqual (`==`) with object coercion: when one side is an Object and the other a
    /// Number/String/Symbol primitive, ToPrimitive(object, default) and retry; otherwise the pure
    /// primitive comparison. (object == object is reference equality, handled by the pure helper.)
    fn looseEqualsV(self: *Interpreter, l: Value, r: Value) EvalError!Completion {
        // §7.2.15 step 10/11: Object vs primitive (number/string/symbol/bigint) → coerce the object.
        const l_obj = l == .object;
        const r_obj = r == .object;
        if (l_obj != r_obj) { // exactly one is an object
            const other = if (l_obj) r else l;
            if (other == .undefined or other == .null) {
                return .{ .normal = .{ .boolean = false } }; // §7.2.15: Object == null/undefined is false
            }
            if (l_obj) {
                const pc = try self.toPrimitive(l, .default);
                if (pc.isAbrupt()) return pc;
                return self.looseEqualsV(pc.normal, r);
            } else {
                const pc = try self.toPrimitive(r, .default);
                if (pc.isAbrupt()) return pc;
                return self.looseEqualsV(l, pc.normal);
            }
        }
        return .{ .normal = .{ .boolean = looseEquals(l, r) } };
    }

    /// §20.5: throw a real Error object carrying `name`/`message`, proto-linked to the realm's
    /// matching Error constructor (so `e instanceof TypeError` and name-based classification work).
    /// §19.2.1.1 PerformEval — parse `source` as a Script and run it in `target_env` on THIS
    /// interpreter (so the live step/depth counters carry through; runaway eval code still terminates
    /// and recursion through eval stays bounded). A parse error → a real `SyntaxError` (§19.2.1 step
    /// 7). The script's completion VALUE is the result (the engine's `run` already returns the last
    /// statement's value). `target_env` is a fresh child of the caller's env for DIRECT eval (reads/
    /// writes of surrounding bindings work; `let`/`const`/`class` are eval-local) or the GLOBAL env for
    /// INDIRECT eval. `this_val`/`home_object` are left at the interpreter's current values (inherited
    /// for direct; the caller resets them for indirect). Non-string `source` is handled by the caller.
    /// §20.2.1.1 / §20.2.1.1.1 CreateDynamicFunction — `Function(p1, …, pN, body)`: the last argument is
    /// the function body, the rest are parameter texts (joined with `,`). Builds the source
    /// `(function anonymous(<params>\n) {\n<body>\n})` and evaluates it in the GLOBAL scope (the dynamic
    /// function closes over global bindings, not the caller's), returning the resulting function. A
    /// malformed parameter/body → a catchable SyntaxError (via performEval). The `\n` after the params
    /// and around the body match the spec text (prevent `//`-comment / `)` injection from hiding the
    /// closing delimiters). The function's name is `anonymous`; its strictness comes from its own body.
    fn functionConstructor(self: *Interpreter, args: []const Value) EvalError!Completion {
        const genv = self.globals orelse return self.throwError("EvalError", "Function: no realm");
        var params: std.ArrayListUnmanaged(u8) = .empty;
        var body: []const u8 = "";
        if (args.len > 0) {
            for (args[0 .. args.len - 1], 0..) |p, i| {
                const sc = try self.toStringValuePub(p);
                if (sc.isAbrupt()) return sc;
                if (i > 0) try params.appendSlice(self.arena, ",");
                try params.appendSlice(self.arena, sc.normal.string);
            }
            const bc = try self.toStringValuePub(args[args.len - 1]);
            if (bc.isAbrupt()) return bc;
            body = bc.normal.string;
        }
        const source = try std.fmt.allocPrint(self.arena, "(function anonymous({s}\n) {{\n{s}\n}})", .{ params.items, body });
        // Evaluate in the global context with the global `this` (the dynamic function is created there).
        const saved_this = self.this_val;
        const saved_home = self.home_object;
        defer {
            self.this_val = saved_this;
            self.home_object = saved_home;
        }
        self.this_val = if (genv.lookup("%GlobalThis%")) |b| b.value else .undefined;
        self.home_object = null;
        return self.performEval(source, genv, false);
    }

    fn performEval(self: *Interpreter, source: []const u8, target_env: *Environment, inherit_strict: bool) EvalError!Completion {
        // §19.2.1.1: the eval code is strict iff it carries its own `"use strict"` prologue OR (DIRECT
        // eval only) the calling context is strict (`inherit_strict`). Parsing with the inherited flag
        // folds both into `program.strict`, which `run` installs as the eval body's runtime strictness.
        const program = Parser.parseMode(self.arena, source, inherit_strict) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // §19.2.1 step 7: a parse failure throws a SyntaxError (a real, catchable error object).
            else => return self.throwError("SyntaxError", "eval: invalid source"),
        };
        // §19.2.1.3: a STRICT eval gets its OWN VariableEnvironment (its `var`s are eval-local); a
        // SLOPPY direct eval's `var`s hoist to the caller's var scope (its fresh eval env is left a
        // non-var-scope so `varScope()` climbs past it). An indirect eval / Function-body eval already
        // targets the global var scope, which this preserves (`or`-ing keeps an existing var scope).
        target_env.is_var_scope = target_env.is_var_scope or program.strict;
        // Reuse `run` (ReturnIfAbrupt over the statement list); the completion value is the last
        // statement's value. Counters are the interpreter's own — not reset, so limits still apply.
        return self.run(program, target_env);
    }

    pub fn throwError(self: *Interpreter, kind: []const u8, msg: []const u8) EvalError!Completion {
        const err = try Object.create(self.arena, self.errorProto(kind));
        err.error_data = true; // §20.5 [[ErrorData]] → §20.1.3.6 "Error" tag
        try err.set("name", .{ .string = kind });
        try err.set("message", .{ .string = msg });
        return .{ .throw = .{ .object = err } };
    }

    fn errorProto(self: *Interpreter, kind: []const u8) ?*Object {
        return self.globalProto(kind);
    }

    /// The `.prototype` object of a named global constructor (Error/Array/…), or null.
    pub fn globalProto(self: *Interpreter, name: []const u8) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup(name) orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("prototype") orelse return null;
        return if (pv == .object) pv.object else null;
    }

    pub fn arrayProto(self: *Interpreter) ?*Object {
        return self.globalProto("Array");
    }

    /// The realm's well-known `Symbol.species` identity (held on the `Symbol` constructor). Null only in
    /// a realm-less unit-test eval (no `Symbol`) — ArraySpeciesCreate then defaults to a plain Array.
    fn wellKnownSpecies(self: *Interpreter) ?*Symbol {
        const g = self.globals orelse return null;
        const b = g.lookup("Symbol") orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("species") orelse return null;
        return if (pv == .symbol) pv.symbol else null;
    }

    /// §10.4.2.3 ArraySpeciesCreate ( originalArray, length ) — the result-array factory used by
    /// filter/map/concat/slice/splice/flat/flatMap. Steps:
    ///   1. originalArray is not an Array exotic → plain ArrayCreate(length) (no `constructor` read).
    ///   2. C = Get(originalArray, "constructor") — a poisoned getter propagates its abrupt completion.
    ///   3. C is an Object → C = Get(C, @@species); a null species is treated as undefined (poisoned
    ///      species getter propagates).
    ///   4. C undefined → plain ArrayCreate(length).
    ///   5. C is not a constructor (incl. a non-object `constructor` value) → TypeError.
    ///   6. else Construct(C, « length »).
    /// Returns the result object as a Value, or the abrupt completion.
    pub fn arraySpeciesCreate(self: *Interpreter, original: *Object, length: usize) EvalError!Completion {
        // §10.4.2.3 step 2: IsArray(originalArray) — false → plain array, constructor untouched.
        if (original.kind != .array) return self.newArray(length);
        // step 3: C = Get(originalArray, "constructor")  (own/inherited; getter may throw).
        const cc = try self.getProperty(.{ .object = original }, "constructor");
        if (cc.isAbrupt()) return cc;
        var c = cc.normal;
        // step 5: if Type(C) is Object, C = Get(C, @@species); a null result → undefined.
        if (c == .object) {
            if (self.wellKnownSpecies()) |sp| {
                const sc = try self.getSymbolProperty(c, sp);
                if (sc.isAbrupt()) return sc;
                c = sc.normal;
            } else {
                // realm-less eval: no species symbol → treat the object constructor as "use default".
                c = .undefined;
            }
            if (c == .null) c = .undefined;
        }
        // step 6: C undefined → plain ArrayCreate(length).
        if (c == .undefined) return self.newArray(length);
        // step 7: IsConstructor(C) is false → TypeError (covers a non-object `constructor` and a
        // non-constructor @@species).
        if (c != .object or !isConstructor(c.object)) {
            return self.throwError("TypeError", "ArraySpeciesCreate: constructor species is not a constructor");
        }
        // step 8: Construct(C, « length »).
        return self.construct(c.object, &.{.{ .number = @floatFromInt(length) }});
    }

    /// §10.4.2.2 ArrayCreate(length): a fresh plain Array exotic of [[Length]] `length` (no eager fill —
    /// a length-only grow is sparse), proto-linked to %Array.prototype%. The default ArraySpeciesCreate
    /// result. A length above 2^32-1 → RangeError (step 1).
    pub fn newArray(self: *Interpreter, length: usize) EvalError!Completion {
        if (length > 4294967295) return self.throwError("RangeError", "Invalid array length");
        const a = try Object.createArray(self.arena, self.arrayProto());
        a.array_length = length;
        return .{ .normal = .{ .object = a } };
    }

    /// §23.1.2.1/.3 the `A` target for Array.from / Array.of: `IsConstructor(C) ? Construct(C, «len») :
    /// ArrayCreate(len)`. `C` is the `this` value of the static call (so `Array.from.call(Ctor, …)` uses
    /// `Ctor`). A non-constructor `this` (e.g. the plain `Array.from(…)` where `this` is the Array ctor,
    /// or an arbitrary non-ctor receiver) → a plain Array. The result is populated by the caller via
    /// CreateDataPropertyOrThrow, so a constructor that returns a non-extensible / locked object throws.
    pub fn arrayCreateFromCtor(self: *Interpreter, this_val: Value, length: usize) EvalError!Completion {
        if (this_val == .object and isConstructor(this_val.object) and this_val.object.native != .array_ctor) {
            return self.construct(this_val.object, &.{.{ .number = @floatFromInt(length) }});
        }
        return self.newArray(length);
    }

    /// §7.3.7 CreateDataPropertyOrThrow ( O, P, V ) — define an own data property
    /// `{ value:V, writable:true, enumerable:true, configurable:true }`, throwing a TypeError if the
    /// definition is rejected. For an Array exotic at an integer index this is the array [[Set]] with
    /// Throw=true: a frozen array (non-writable elements) or a non-extensible array gaining a NEW index
    /// rejects → TypeError. For a generic object (a non-Array species result) it routes through
    /// [[DefineOwnProperty]] so a configurable non-writable existing prop is redefined writable.
    /// Returns `.normal = undefined` on success, or the abrupt `.thrown` completion (caller propagates).
    pub fn createDataPropertyOrThrow(self: *Interpreter, target: *Object, index: usize, value: Value) EvalError!Completion {
        if (target.kind == .array) {
            // Throw=true array [[Set]]: reject a write to a frozen element or a new index on a
            // non-extensible array (independent of strict mode — the method always throws).
            if (target.array_frozen) return self.throwError("TypeError", "Cannot add property to a frozen array");
            if (!target.extensible and !target.arrayHas(index)) {
                return self.throwError("TypeError", "Cannot add property to a non-extensible array");
            }
            try target.arraySet(self.arena, index, value);
            // §7.3.5 CreateDataProperty overwrites with default attributes — drop any stale string-keyed
            // entry for this index (e.g. a non-writable index installed via Object.defineProperty on the
            // species result) so the index now reads as a writable/enumerable/configurable own property.
            if (target.properties.count() != 0) _ = target.properties.orderedRemove(numberToString(self.arena, @floatFromInt(index)) catch return error.OutOfMemory);
            return .{ .normal = .undefined };
        }
        // Generic object: §10.1.6 [[DefineOwnProperty]] with the data-property defaults.
        const key = try numberToString(self.arena, @floatFromInt(index));
        const ok = try target.defineProperty(key, .{
            .value = value,
            .has_value = true,
            .writable = true,
            .enumerable = true,
            .configurable = true,
        });
        if (!ok) return self.throwError("TypeError", "CreateDataPropertyOrThrow: defining the property failed");
        return .{ .normal = .undefined };
    }

    /// §10.4.2.4-style array element [[Set]] with Throw=true, used by the in-place mutating methods
    /// (push/unshift/shift/splice/fill/copyWithin/reverse/sort). Like `createDataPropertyOrThrow` for an
    /// array but tolerant of overwriting an existing index on an extensible array (the common case).
    /// Returns `.normal = undefined` on success, or the abrupt `.thrown` completion.
    pub fn arraySetThrow(self: *Interpreter, arr: *Object, index: usize, value: Value) EvalError!Completion {
        if (arr.array_frozen) return self.throwError("TypeError", "Cannot modify a frozen array");
        if (!arr.extensible and !arr.arrayHas(index)) {
            return self.throwError("TypeError", "Cannot add property to a non-extensible array");
        }
        try arr.arraySet(self.arena, index, value);
        return .{ .normal = .undefined };
    }

    /// §10.4.2.4 array [[Set]] of `length` with Throw=true — a non-writable `length` (frozen array, or
    /// `defineProperty(arr,"length",{writable:false})`) rejects ANY length [[Set]], including one to the
    /// SAME value (ArraySetLength step 17 returns false → Set with Throw=true throws). Matches V8: the
    /// length Set the mutating methods always perform throws even when the value is unchanged.
    pub fn arraySetLenThrow(self: *Interpreter, arr: *Object, n: usize) EvalError!Completion {
        if (!arr.array_length_writable) {
            return self.throwError("TypeError", "Cannot assign to read only property 'length' of array");
        }
        try arr.arraySetLen(n);
        return .{ .normal = .undefined };
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

    /// §27.1.4 %Iterator.prototype% — the [[Prototype]] of every built-in iterator (so the helper
    /// methods are inherited). Falls back to %Object.prototype% in a realm-less eval (no Iterator).
    pub fn iteratorProto(self: *Interpreter) ?*Object {
        const g = self.globals orelse return self.objectProto();
        const b = g.lookup("%IteratorPrototype%") orelse return self.objectProto();
        return if (b.value == .object) b.value.object else self.objectProto();
    }

    // ── §20.1.2 / §20.1.3 Object reflection ─────────────────────────────────

    /// §6.2.6 ToPropertyDescriptor — read a descriptor object's own `value`/`writable`/`get`/`set`/
    /// `enumerable`/`configurable` fields into a `Descriptor` (each present-or-absent via HasProperty).
    /// `get`/`set` must be callable or `undefined` (TypeError otherwise). Returns null+throw on error.
    pub fn toPropertyDescriptor(self: *Interpreter, attrs: Value) EvalError!union(enum) { desc: object_mod.Descriptor, abrupt: Completion } {
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

    /// §7.3.23 own ENUMERABLE string keys of `value` — a thin wrapper kept on the Interpreter so JSON
    /// and other built-ins reach the helper now living in builtin_object.
    pub fn ownEnumerableKeys(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!void {
        return builtin_object.ownEnumerableKeys(self, value, out);
    }

    /// §7.1.19 ToPropertyKey then ToString — a thin wrapper kept on the Interpreter so Object/Reflect
    /// reach the helper now living in builtin_reflect.zig.
    pub fn toPropertyKeyString(self: *Interpreter, key: Value) EvalError![]const u8 {
        return builtin_reflect.toPropertyKeyString(self, key);
    }
    // ── §21.3 Math ──────────────────────────────────────────────────────────

    /// §21.3.2.27 Math.random — the next xorshift64* draw mapped to [0,1). A fixed-seed PRNG (no host
    /// entropy in this sandbox; the engine is deterministic). Uses the top 53 bits for a uniform double.
    pub fn randomNext(self: *Interpreter) f64 {
        var s = self.rng_state;
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        self.rng_state = s;
        const bits: u64 = (s *% 0x2545F4914F6CDD1D) >> 11; // 53 significant bits
        return @as(f64, @floatFromInt(bits)) * (1.0 / 9007199254740992.0); // / 2^53
    }

    /// §7.3.12 HasProperty for a Value key (string or symbol) — proto-chain walk (the `in` semantics).
    pub fn hasPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!bool {
        const o = base.object;
        if (key == .symbol) return o.getSymbolProp(key.symbol) != null;
        const ks = try self.toPropertyKeyString(key);
        if (o.kind == .array) {
            if (std.mem.eql(u8, ks, "length")) return true;
            if (parseIndex(ks)) |i| if (o.arrayHas(i)) return true;
        }
        return o.get(ks) != null;
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
            // §20.2.3.2 step 4–8: a bound function's `length` is max(0, target.length - boundArgs)
            // (target.length coerced to an integer; a non-number/absent → 0); its `name` is
            // "bound " + target.name (target.name coerced to string; a non-string → "").
            var target_len: f64 = 0;
            if (target.get("length")) |lv| if (lv == .number and lv.number > 0 and std.math.isFinite(lv.number)) {
                target_len = @trunc(lv.number);
            };
            const bound_len = @max(0, target_len - @as(f64, @floatFromInt(bound_args.len)));
            try setFunctionLength(bf, bound_len);
            const target_name = if (target.get("name")) |nv| (if (nv == .string) nv.string else "") else "";
            try self.setFunctionName(bf, target_name, "bound");
            return .{ .normal = .{ .object = bf } };
        }

        return self.throwError("TypeError", "unknown Function.prototype method");
    }

    /// §7.3.18 CreateListFromArrayLike (§20.2.3.1 step 2): null/undefined → empty list; an Array →
    /// its elements; any other object → its `0..length-1` indexed values (M-subset: array-likes via
    /// `.length`); a non-object non-nullish argArray → TypeError.
    pub fn createListFromArrayLike(self: *Interpreter, v: Value) EvalError!union(enum) { list: []const Value, abrupt: Completion } {
        switch (v) {
            .undefined, .null => return .{ .list = &.{} },
            .object => |o| {
                // Fast path ONLY for a TRULY dense array: backing store == [0..length) with every
                // index an own data property. A sparse array / one with holes (e.g. `[1,,2]`, whose
                // gap spilled to `sparse`) must NOT short-circuit here — its `elements.items` omits
                // the holes, so it would drop arguments. Fall through to LengthOfArrayLike + Get,
                // which reads each hole index as `undefined` (CreateListFromArrayLike, §7.3.18).
                if (o.kind == .array and o.array_length == o.elements.items.len and
                    (o.holes == null or o.holes.?.count() == 0) and
                    (o.sparse == null or o.sparse.?.count() == 0))
                    return .{ .list = o.elements.items };
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

    // ── §19.2 global function intrinsics ─────────────────────────────────────────

    /// §19.2 dispatch the global functions by name (the `global_fn` native).
    fn globalFn(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
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
        if (std.mem.eql(u8, name, "parseInt")) return self.parseIntFn(args);
        if (std.mem.eql(u8, name, "parseFloat")) return self.parseFloatFn(args);
        // §19.2.6 the URI handlers — encode/decode select via the preserved-char sets.
        if (std.mem.eql(u8, name, "encodeURI")) return self.uriEncode(arg0, .uri);
        if (std.mem.eql(u8, name, "encodeURIComponent")) return self.uriEncode(arg0, .component);
        if (std.mem.eql(u8, name, "decodeURI")) return self.uriDecode(arg0, .uri);
        if (std.mem.eql(u8, name, "decodeURIComponent")) return self.uriDecode(arg0, .component);
        unreachable;
    }

    /// §19.2.5 parseInt ( string, radix ).
    fn parseIntFn(self: *Interpreter, args: []const Value) EvalError!Completion {
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
    fn parseFloatFn(self: *Interpreter, args: []const Value) EvalError!Completion {
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

    const UriKind = enum { uri, component };

    /// §19.2.6.4/.5 Encode — percent-encode the UTF-8 bytes of `v`, preserving the kind's unescaped
    /// (and, for encodeURI, reserved) set. A lone surrogate in the source → URIError.
    fn uriEncode(self: *Interpreter, v: Value, kind: UriKind) EvalError!Completion {
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
    fn uriDecode(self: *Interpreter, v: Value, kind: UriKind) EvalError!Completion {
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

    // ── §21.1.3 Number.prototype methods ─────────────────────────────────────────

    /// Dispatch a built-in function (§19/§20). Behavior keyed by `func.native`.
    fn callNative(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
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
                const ic = try self.initCollectionInstance(func.native, this_val.object, args);
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
            .collection_size => return self.collectionSize(func.native_name, this_val),
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
                return self.makeCollectionIterator(this_val, kind, home);
            },
            .math_method => return builtin_math.call(self, func.native_name, args),
            .reflect_method => return builtin_reflect.reflectMethod(self, func.native_name, args),
            .species_getter => return .{ .normal = this_val }, // §23.1.2.5 get [Symbol.species] returns `this`
            .array_values => return self.makeArrayIterator(this_val, .value), // §23.1.3.34 / Array.prototype[Symbol.iterator]
            .array_keys => return self.makeArrayIterator(this_val, .key), // §23.1.3.18 Array.prototype.keys
            .array_entries => return self.makeArrayIterator(this_val, .entry), // §23.1.3.7 Array.prototype.entries
            .string_iterator => return self.makeStringIterator(this_val), // §22.1.3.36 String.prototype[Symbol.iterator]
            .iterator_next => return self.iteratorNext(this_val), // §23.1.5.2.1 / §22.1.5.2.1 %…IteratorPrototype%.next
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
                return self.generatorResume(this_val, kind, arg);
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
                return self.asyncGeneratorResume(this_val, kind, arg);
            },
            .async_generator_iterator => return .{ .normal = this_val }, // §27.6.1.5 / §27.1.4.2.4 returns `this`
            .async_from_sync_method => { // §27.1.4.2 %AsyncFromSyncIteratorPrototype%.next/return/throw
                const arg: Value = if (args.len > 0) args[0] else .undefined;
                const has_arg = args.len > 0;
                return self.asyncFromSyncMethod(func.native_name, this_val, arg, has_arg);
            },
            .async_from_sync_wrap => { // §27.1.4.4: wrap an awaited value into { value, done }
                const v: Value = if (args.len > 0) args[0] else .undefined;
                const ir = try self.iterResultObject(v, func.afs_done);
                return .{ .normal = .{ .object = ir } };
            },
            // §27.2 Promise — the prototype methods (need `this`) + the resolving/finally thunks.
            .promise_then => return self.promiseThen(this_val, args),
            .promise_catch => return self.promiseCatch(this_val, args),
            .promise_finally => return self.promiseFinally(this_val, args),
            .promise_resolve => return self.promiseStaticResolve(args),
            .promise_reject => return self.promiseStaticReject(args),
            .promise_all => return self.promiseCombinator(args, .all),
            .promise_all_settled => return self.promiseCombinator(args, .all_settled),
            .promise_any => return self.promiseCombinator(args, .any),
            .promise_race => return self.promiseCombinator(args, .race),
            .promise_combinator_element => return self.promiseCombinatorElement(func, args),
            .promise_resolve_fn, .promise_reject_fn => return self.promiseResolvingFn(func, args),
            .promise_finally_thunk => return self.promiseFinallyThunk(func, args),
            .test_done => return self.testDone(args),
            .global_fn => return self.globalFn(func.native_name, args), // §19.2 global function intrinsics
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
                return self.performEval(arg.string, genv, false);
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
                const v: Value = if (args.len > 0) args[0] else .undefined;
                const s: []const u8 = if (v == .object) blk: {
                    const pc = try self.toPrimitive(v, .string);
                    if (pc.isAbrupt()) return pc;
                    break :blk try self.toString(pc.normal);
                } else try self.toString(v);
                return self.wrapperResult(.{ .string = s }, this_val); // §22.1.1.1 box [[StringData]] on new/super
            },
            .number_ctor => { // §21.1.1.1 Number ( value ) — ToNumber (ToPrimitive(number) an object first).
                const v: Value = if (args.len > 0) args[0] else .undefined;
                const prim: Value = if (args.len == 0) .{ .number = 0 } else blk: {
                    const nc = try self.toNumberV(v);
                    if (nc.isAbrupt()) return nc;
                    break :blk nc.normal;
                };
                return self.wrapperResult(prim, this_val); // §21.1.1.1 box [[NumberData]] on `new`/`super`
            },
            // §20.3.1.1 Boolean ( value ) — ToBoolean (no ToPrimitive). Box [[BooleanData]] on new/super.
            .boolean_ctor => return self.wrapperResult(.{ .boolean = args.len > 0 and toBoolean(args[0]) }, this_val),
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
                // §20.1.1.1 Object ( [ value ] ): an object argument is returned as-is; otherwise a fresh
                // ordinary object is created proto-linked to %Object.prototype% (so its inherited
                // `toString`/`hasOwnProperty`/etc. — and thus ToPrimitive — resolve).
                if (args.len > 0 and args[0] == .object) return .{ .normal = args[0] };
                return .{ .normal = .{ .object = try Object.create(self.arena, self.objectProto()) } };
            },
            .object_to_string => return builtin_object.objectToString(self, this_val),
            // §20.1.3.7 Object.prototype.valueOf returns ToObject(this). For an object receiver that is
            // the receiver itself (so OrdinaryToPrimitive's valueOf step yields a non-primitive and falls
            // through to toString — the default object→"[object Object]" behavior). undefined/null throw.
            .object_value_of => return switch (this_val) {
                .undefined, .null => self.throwError("TypeError", "Object.prototype.valueOf called on null or undefined"),
                else => .{ .normal = this_val },
            },
            .function_ctor => return self.functionConstructor(args),
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
            .function_method => return self.functionPrototypeMethod(func.native_name, this_val, args),
            .bigint_ctor => return builtin_bigint.bigintConstructor(self, args), // §21.2.1.1 BigInt(value)
            .bigint_static => return builtin_bigint.bigintStatic(self, func.native_name, args), // §21.2.2 asIntN/asUintN
            .bigint_method => return builtin_bigint.bigintMethod(self, func.native_name, this_val, args), // §21.2.3 toString/valueOf
            .symbol_ctor => return builtin_symbol.constructor(self, args), // §20.4.1.1 Symbol([description])
            .promise_ctor => return self.promiseConstructor(args), // §27.2.3.1 Promise(executor) called w/o new
            .array_ctor, .array_method, .array_static, .string_method, .string_static, .math_method, .reflect_method => unreachable, // handled in the first switch
            .species_getter, .array_values, .array_keys, .array_entries, .string_iterator, .iterator_next, .symbol_to_string => unreachable, // handled in the first switch
            .symbol_static, .symbol_description => unreachable, // handled in the first switch
            .generator_method, .generator_iterator => unreachable, // handled in the first switch
            .async_generator_method, .async_generator_iterator, .async_from_sync_method, .async_from_sync_wrap => unreachable, // handled in the first switch
            .map_method, .set_method, .weakmap_method, .weakset_method => unreachable, // handled in the first switch
            .map_ctor, .set_ctor, .weakmap_ctor, .weakset_ctor, .collection_size, .collection_iterator => unreachable, // handled in the first switch
            .proxy_ctor, .proxy_revocable, .proxy_revoke => unreachable, // handled in the first switch
            .regexp_ctor, .regexp_proto_getter, .regexp_to_string, .regexp_exec, .regexp_test => unreachable, // handled in the first switch
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
    fn makeArgumentsObject(self: *Interpreter, args: []const Value, func: *Object, call_env: *Environment, fd: object_mod.FunctionData) EvalError!*Object {
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
    fn isSimpleParamList(fd: object_mod.FunctionData) bool {
        if (fd.rest != null) return false;
        for (fd.params) |p| {
            if (p.default != null) return false;
            if (p.pattern.* != .identifier) return false;
        }
        return true;
    }

    /// §23.1.5.1 CreateArrayIterator — a fresh Array Iterator object (proto = %Object.prototype% in the
    /// M-subset) carrying the array + cursor in its native `iter` slot, with a `next` method.
    fn makeArrayIterator(self: *Interpreter, this_val: Value, kind: @import("object.zig").IterKind) EvalError!Completion {
        if (this_val != .object) return self.throwError("TypeError", "Array.prototype.values requires an object");
        const iter = try Object.create(self.arena, self.iteratorProto()); // §23.1.5.1 proto = %Iterator.prototype%
        iter.iter = .{ .array = this_val.object, .cursor = 0, .kind = kind };
        try self.installIteratorNext(iter);
        return .{ .normal = .{ .object = iter } };
    }

    /// §24.1.1.1 / §24.2.1.1 collection construction: attach a fresh `Collection` of the right kind to
    /// `new_obj`, then §24.1.1.2 AddEntriesFromIterable — if the iterable arg is non-nullish, get the
    /// instance's (possibly subclass-overridden) `set`/`add` adder and feed each iterated record to it.
    fn initCollectionInstance(self: *Interpreter, native: object_mod.NativeId, new_obj: *Object, args: []const Value) EvalError!Completion {
        const kind: object_mod.CollectionKind = switch (native) {
            .map_ctor => .map,
            .set_ctor => .set,
            .weakmap_ctor => .weakmap,
            .weakset_ctor => .weakset,
            else => unreachable,
        };
        const coll = try self.arena.create(object_mod.Collection);
        coll.* = .{ .kind = kind };
        new_obj.collection = coll;

        const iterable: Value = if (args.len > 0) args[0] else .undefined;
        if (iterable == .undefined or iterable == .null) return .{ .normal = .undefined };

        // §24.1.1.2 step 2: adder = Get(target, "set"/"add"); must be callable.
        const is_keyed = (kind == .map or kind == .weakmap);
        const adder_name: []const u8 = if (is_keyed) "set" else "add";
        const ac = try self.getProperty(.{ .object = new_obj }, adder_name);
        if (ac.isAbrupt()) return ac;
        if (ac.normal != .object or !isCallable(ac.normal.object)) {
            return self.throwError("TypeError", "collection adder is not callable");
        }
        const adder = ac.normal.object;

        const itr: *Object = switch (try self.getIterator(iterable)) {
            .iterator => |x| x,
            .abrupt => |c| return c,
        };
        // §24.1.1.2 step 4: for each record, call the adder; an abrupt completion closes the iterator.
        while (true) {
            const step = try self.iteratorStep(itr);
            switch (step) {
                .done => break,
                .abrupt => |c| return c,
                .value => |v| {
                    if (is_keyed) {
                        // §24.1.1.2 step 4.d: each Map entry must be an object with [0]/[1].
                        if (v != .object) {
                            const e = try self.throwError("TypeError", "Iterator value is not an entry object");
                            try self.iteratorClose(itr);
                            return e;
                        }
                        const k0 = try self.getProperty(v, "0");
                        if (k0.isAbrupt()) {
                            try self.iteratorClose(itr);
                            return k0;
                        }
                        const v1 = try self.getProperty(v, "1");
                        if (v1.isAbrupt()) {
                            try self.iteratorClose(itr);
                            return v1;
                        }
                        const r = try self.callFunction(adder, &.{ k0.normal, v1.normal }, .{ .object = new_obj });
                        if (r.isAbrupt()) {
                            try self.iteratorClose(itr);
                            return r;
                        }
                    } else {
                        const r = try self.callFunction(adder, &.{v}, .{ .object = new_obj });
                        if (r.isAbrupt()) {
                            try self.iteratorClose(itr);
                            return r;
                        }
                    }
                },
            }
        }
        return .{ .normal = .undefined };
    }

    /// §24.1.5.1 / §24.2.5.1 CreateMapIterator / CreateSetIterator — a fresh iterator object (proto =
    /// %Object.prototype% in the M-subset) carrying the collection + cursor in its `iter` slot. Requires
    /// `this` to be a Map/Set instance (not a Weak collection — those are not iterable).
    fn makeCollectionIterator(self: *Interpreter, this_val: Value, kind: object_mod.IterKind, home: object_mod.CollectionKind) EvalError!Completion {
        if (this_val != .object or this_val.object.collection == null) {
            return self.throwError("TypeError", "method called on an incompatible receiver");
        }
        const c = this_val.object.collection.?;
        // Brand: the receiver must be the SAME collection kind the method lives on (a Map iterator on a
        // Set, or vice versa, throws). Weak collections have no iterators so they never match here.
        if (c.kind != home) {
            return self.throwError("TypeError", "method called on an incompatible receiver");
        }
        const iter = try Object.create(self.arena, self.iteratorProto()); // §24.1.5.1 proto = %Iterator.prototype%
        iter.iter = .{ .collection = this_val.object, .cursor = 0, .kind = kind };
        try self.installIteratorNext(iter);
        return .{ .normal = .{ .object = iter } };
    }

    /// §24.1.3.10 / §24.2.3.9 get size — the count of present entries. `native_name` carries the brand
    /// ("map"/"set") so the Map getter rejects a Set receiver (distinct [[MapData]]/[[SetData]] slots).
    fn collectionSize(self: *Interpreter, native_name: []const u8, this_val: Value) EvalError!Completion {
        const want: object_mod.CollectionKind = if (std.mem.eql(u8, native_name, "set")) .set else .map;
        if (this_val == .object) {
            if (this_val.object.collection) |c| {
                if (c.kind == want) return .{ .normal = .{ .number = @floatFromInt(c.size) } };
            }
        }
        return self.throwError("TypeError", "get size called on an incompatible receiver");
    }

    /// §24.2.1.2 Set Record — a set-LIKE argument (`other`), duck-typed via `size`/`has`/`keys`. NOT
    /// necessarily a real Set, so the algebra below must call `has`/`keys` dynamically (observably).
    const SetRecord = struct { obj: Value, size: f64, has: *Object, keys: *Object };

    /// §24.2.1.2 GetSetRecord ( obj ) — validate the set-like and capture its size/has/keys.
    fn getSetRecord(self: *Interpreter, obj: Value) EvalError!union(enum) { rec: SetRecord, abrupt: Completion } {
        if (obj != .object) return .{ .abrupt = try self.throwError("TypeError", "argument is not an object") };
        const sc = try self.getProperty2(obj, "size");
        if (sc.isAbrupt()) return .{ .abrupt = sc };
        const nc = try self.toNumberV(sc.normal); // ToNumber(undefined) = NaN → TypeError below
        if (nc.isAbrupt()) return .{ .abrupt = nc };
        if (std.math.isNan(nc.normal.number)) return .{ .abrupt = try self.throwError("TypeError", "size is NaN") };
        const isc = try self.toIntegerOrInfinityPub(nc.normal);
        if (isc.isAbrupt()) return .{ .abrupt = isc };
        const int_size = isc.normal.number;
        if (int_size < 0) return .{ .abrupt = try self.throwError("RangeError", "size is negative") };
        const hc = try self.getProperty2(obj, "has");
        if (hc.isAbrupt()) return .{ .abrupt = hc };
        if (hc.normal != .object or !isCallable(hc.normal.object)) return .{ .abrupt = try self.throwError("TypeError", "has is not callable") };
        const kc = try self.getProperty2(obj, "keys");
        if (kc.isAbrupt()) return .{ .abrupt = kc };
        if (kc.normal != .object or !isCallable(kc.normal.object)) return .{ .abrupt = try self.throwError("TypeError", "keys is not callable") };
        return .{ .rec = .{ .obj = obj, .size = int_size, .has = hc.normal.object, .keys = kc.normal.object } };
    }

    /// %Set.prototype% intrinsic (for the result of the set-algebra methods). Null in a realm-less eval.
    fn setProto(self: *Interpreter) ?*Object {
        const g = self.globals orelse return null;
        const b = g.lookup("Set") orelse return null;
        if (b.value != .object) return null;
        const pv = b.value.object.get("prototype") orelse return null;
        return if (pv == .object) pv.object else null;
    }

    /// A fresh empty Set instance (proto = %Set.prototype%, kind=set) — the result container.
    fn newSetInstance(self: *Interpreter) EvalError!*Object {
        const o = try Object.create(self.arena, self.setProto());
        const coll = try self.arena.create(object_mod.Collection);
        coll.* = .{ .kind = .set };
        o.collection = coll;
        return o;
    }

    /// A new Set seeded with a SNAPSHOT of `src`'s present elements (in insertion order) — the
    /// `resultSetData ← copy of O.[[SetData]]` step shared by union/difference/symmetricDifference.
    fn cloneSet(self: *Interpreter, src: *object_mod.Collection) EvalError!*Object {
        const o = try self.newSetInstance();
        for (src.entries.items) |e| {
            if (e.present) try builtin_collection.addElement(self, o.collection.?, e.key);
        }
        return o;
    }

    /// Call `other.keys()` and require an object result — the iterator for the set-algebra walks.
    fn setRecordKeysIter(self: *Interpreter, rec: SetRecord) EvalError!union(enum) { iter: *Object, abrupt: Completion } {
        const kc = try self.callFunction(rec.keys, &.{}, rec.obj);
        if (kc.isAbrupt()) return .{ .abrupt = kc };
        if (kc.normal != .object) return .{ .abrupt = try self.throwError("TypeError", "keys() did not return an object") };
        return .{ .iter = kc.normal.object };
    }

    /// §24.2.3 union/intersection/difference/symmetricDifference/isSubsetOf/isSupersetOf/isDisjointFrom.
    /// `this_coll` is the already-brand-checked Set; `args[0]` is the set-like `other`.
    pub fn setAlgebra(self: *Interpreter, name: []const u8, this_coll: *object_mod.Collection, args: []const Value) EvalError!Completion {
        const eql = std.mem.eql;
        const other: Value = if (args.len > 0) args[0] else .undefined;
        const rec = switch (try self.getSetRecord(other)) {
            .rec => |r| r,
            .abrupt => |c| return c,
        };
        const this_size: f64 = @floatFromInt(this_coll.size);

        if (eql(u8, name, "union")) {
            // §24.2.3.x: result = clone(O); add each of other's keys.
            const result = try self.cloneSet(this_coll);
            const iter = switch (try self.setRecordKeysIter(rec)) {
                .iter => |x| x,
                .abrupt => |c| return c,
            };
            while (true) {
                switch (try self.iteratorStep(iter)) {
                    .done => break,
                    .abrupt => |c| return c,
                    .value => |v| try builtin_collection.addElement(self, result.collection.?, v),
                }
            }
            return .{ .normal = .{ .object = result } };
        }

        if (eql(u8, name, "intersection")) {
            const result = try self.newSetInstance();
            if (this_size <= rec.size) {
                var i: usize = 0;
                while (i < this_coll.entries.items.len) : (i += 1) {
                    if (!this_coll.entries.items[i].present) continue;
                    const e = this_coll.entries.items[i].key;
                    const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                    if (hc.isAbrupt()) return hc;
                    if (toBoolean(hc.normal) and builtin_collection.contains(this_coll, e)) {
                        try builtin_collection.addElement(self, result.collection.?, e);
                    }
                }
            } else {
                const iter = switch (try self.setRecordKeysIter(rec)) {
                    .iter => |x| x,
                    .abrupt => |c| return c,
                };
                while (true) {
                    switch (try self.iteratorStep(iter)) {
                        .done => break,
                        .abrupt => |c| return c,
                        .value => |v| if (builtin_collection.contains(this_coll, v)) try builtin_collection.addElement(self, result.collection.?, v),
                    }
                }
            }
            return .{ .normal = .{ .object = result } };
        }

        if (eql(u8, name, "difference")) {
            const result = try self.cloneSet(this_coll);
            if (this_size <= rec.size) {
                var i: usize = 0;
                while (i < this_coll.entries.items.len) : (i += 1) {
                    if (!this_coll.entries.items[i].present) continue;
                    const e = this_coll.entries.items[i].key;
                    const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                    if (hc.isAbrupt()) return hc;
                    if (toBoolean(hc.normal)) builtin_collection.removeElement(result.collection.?, e);
                }
            } else {
                const iter = switch (try self.setRecordKeysIter(rec)) {
                    .iter => |x| x,
                    .abrupt => |c| return c,
                };
                while (true) {
                    switch (try self.iteratorStep(iter)) {
                        .done => break,
                        .abrupt => |c| return c,
                        .value => |v| builtin_collection.removeElement(result.collection.?, v),
                    }
                }
            }
            return .{ .normal = .{ .object = result } };
        }

        if (eql(u8, name, "symmetricDifference")) {
            const result = try self.cloneSet(this_coll);
            const iter = switch (try self.setRecordKeysIter(rec)) {
                .iter => |x| x,
                .abrupt => |c| return c,
            };
            while (true) {
                switch (try self.iteratorStep(iter)) {
                    .done => break,
                    .abrupt => |c| return c,
                    .value => |v| {
                        // In O → exclude (remove from result); not in O → include (add).
                        if (builtin_collection.contains(this_coll, v)) {
                            builtin_collection.removeElement(result.collection.?, v);
                        } else {
                            try builtin_collection.addElement(self, result.collection.?, v);
                        }
                    },
                }
            }
            return .{ .normal = .{ .object = result } };
        }

        if (eql(u8, name, "isSubsetOf")) {
            if (this_size > rec.size) return .{ .normal = .{ .boolean = false } };
            var i: usize = 0;
            while (i < this_coll.entries.items.len) : (i += 1) {
                if (!this_coll.entries.items[i].present) continue;
                const e = this_coll.entries.items[i].key;
                const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                if (hc.isAbrupt()) return hc;
                if (!toBoolean(hc.normal)) return .{ .normal = .{ .boolean = false } };
            }
            return .{ .normal = .{ .boolean = true } };
        }

        if (eql(u8, name, "isSupersetOf")) {
            if (this_size < rec.size) return .{ .normal = .{ .boolean = false } };
            const iter = switch (try self.setRecordKeysIter(rec)) {
                .iter => |x| x,
                .abrupt => |c| return c,
            };
            while (true) {
                switch (try self.iteratorStep(iter)) {
                    .done => break,
                    .abrupt => |c| return c,
                    .value => |v| if (!builtin_collection.contains(this_coll, v)) {
                        try self.iteratorClose(iter); // §24.2.3 IteratorClose(_, false)
                        return .{ .normal = .{ .boolean = false } };
                    },
                }
            }
            return .{ .normal = .{ .boolean = true } };
        }

        if (eql(u8, name, "isDisjointFrom")) {
            if (this_size <= rec.size) {
                var i: usize = 0;
                while (i < this_coll.entries.items.len) : (i += 1) {
                    if (!this_coll.entries.items[i].present) continue;
                    const e = this_coll.entries.items[i].key;
                    const hc = try self.callFunction(rec.has, &.{e}, rec.obj);
                    if (hc.isAbrupt()) return hc;
                    if (toBoolean(hc.normal)) return .{ .normal = .{ .boolean = false } };
                }
            } else {
                const iter = switch (try self.setRecordKeysIter(rec)) {
                    .iter => |x| x,
                    .abrupt => |c| return c,
                };
                while (true) {
                    switch (try self.iteratorStep(iter)) {
                        .done => break,
                        .abrupt => |c| return c,
                        .value => |v| if (builtin_collection.contains(this_coll, v)) {
                            try self.iteratorClose(iter);
                            return .{ .normal = .{ .boolean = false } };
                        },
                    }
                }
            }
            return .{ .normal = .{ .boolean = true } };
        }

        unreachable;
    }

    /// §22.1.5.1 CreateStringIterator — a fresh String Iterator object over the primitive string's
    /// code units (M-subset: byte-at-a-time, matching the engine's String indexing model).
    fn makeStringIterator(self: *Interpreter, this_val: Value) EvalError!Completion {
        const s: []const u8 = switch (this_val) {
            .string => |str| str,
            else => return self.throwError("TypeError", "String.prototype[Symbol.iterator] requires a string"),
        };
        const iter = try Object.create(self.arena, self.iteratorProto()); // §22.1.5.1 proto = %Iterator.prototype%
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
        // §27.1.2.1 %IteratorPrototype%[Symbol.iterator]() returns `this` — so the iterator object is
        // itself iterable (`for (x of arr.entries())`, `[...arr.keys()]`). Reuses the return-`this`
        // native. Keyed by the realm's well-known Symbol.iterator (absent only in a realm-less eval).
        if (self.wellKnownIterator()) |iter_sym| {
            const self_fn = try Object.createNative(self.arena, .generator_iterator, "[Symbol.iterator]");
            self_fn.prototype = self.functionProto();
            try iter.defineSymbolData(iter_sym, .{ .object = self_fn }, true, false, true);
        }
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
        if (st.collection) |cobj| {
            // §24.1.5.2 / §24.2.5.2: advance over the backing entries, SKIPPING tombstones; yield
            // key / value / [key,value] per the iterator kind. Entries added since creation are seen.
            const c = cobj.collection.?;
            while (st.cursor < c.entries.items.len) {
                const e = c.entries.items[st.cursor];
                st.cursor += 1;
                if (!e.present) continue;
                done = false;
                value = switch (st.kind) {
                    .value => e.value,
                    .key => e.key,
                    .entry => blk: { // [key, value] pair (for a Set, key === value)
                        const pair = try Object.createArray(self.arena, self.arrayProto());
                        try pair.elements.append(self.arena, e.key);
                        try pair.elements.append(self.arena, e.value);
                        pair.array_length = 2;
                        break :blk .{ .object = pair };
                    },
                };
                break;
            }
            // §24.1.5.2 step 11.b: once the iterator runs off the end it is COMPLETE — null the backing
            // link so entries added AFTER exhaustion are not resurrected by a later `next()`.
            if (done) st.collection = null;
        } else if (st.array) |arr| {
            if (st.cursor < arr.arrayLen()) {
                const idx = st.cursor;
                value = switch (st.kind) {
                    .value => arr.arrayGet(idx),
                    .key => .{ .number = @floatFromInt(idx) },
                    .entry => blk: { // [index, value] pair (§23.1.5.2.1)
                        const pair = try Object.createArray(self.arena, self.arrayProto());
                        try pair.elements.append(self.arena, .{ .number = @floatFromInt(idx) });
                        try pair.elements.append(self.arena, arr.arrayGet(idx));
                        break :blk .{ .object = pair };
                    },
                };
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

    /// §7.1.17 ToString — the FULL throwing form (ToPrimitive(string) on an object, TypeError on a
    /// Symbol). Public so the string library (§22.1.3) can coerce `this`/arguments with the observable
    /// abrupt completions the spec mandates (e.g. `"".endsWith(Symbol())` → TypeError). Returns the
    /// string, or the abrupt completion when coercion throws.
    pub fn toStringThrowing(self: *Interpreter, v: Value) EvalError!Completion {
        return switch (try self.toStringCoerceV(v)) {
            .string => |s| .{ .normal = .{ .string = s } },
            .abrupt => |c| c,
        };
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

// ── §19.2 global-function lexical helpers ────────────────────────────────────

/// Length of the leading run of §22.1.3.32 StrWhiteSpace (WhiteSpace + LineTerminator) bytes in `s`.
/// Handles ASCII white space and the multi-byte Unicode space code points (and U+2028/U+2029).
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

/// §12.2/§12.3: the ASCII bytes that are StrWhiteSpace — TAB, LF, VT, FF, CR, SP.
fn isStrWhiteSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

/// §12.2 WhiteSpace + §12.3 LineTerminator — the non-ASCII code points that are StrWhiteSpace.
fn isUnicodeWhiteSpaceCp(cp: u21) bool {
    return switch (cp) {
        0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Digit value of an ASCII char for radix parsing: '0'..'9' → 0..9, 'a'..'z'/'A'..'Z' → 10..35; else null.
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

/// Read the `%XX` at `s[at]`; returns the byte, or null if not `%` + two hex digits.
fn decodeHexByte(s: []const u8, at: usize) ?u8 {
    if (at + 2 >= s.len or s[at] != '%') return null;
    const hi = hexValue(s[at + 1]) orelse return null;
    const lo = hexValue(s[at + 2]) orelse return null;
    return hi * 16 + lo;
}

/// Append `%XX` (uppercase hex) for one byte to `out`.
fn appendPercent(arena: std.mem.Allocator, out: *std.ArrayList(u8), b: u8) std.mem.Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    try out.append(arena, '%');
    try out.append(arena, hex[b >> 4]);
    try out.append(arena, hex[b & 0x0F]);
}

/// §19.2.6.1.1 uriReserved ∪ '#' — the bytes decodeURI preserves and encodeURI keeps in addition to
/// the unescaped set: `; / ? : @ & = + $ , #`.
fn isUriReserved(c: u8) bool {
    return switch (c) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

/// Is byte `c` preserved (not percent-encoded) by the given URI encode kind? `c` is ASCII.
/// uriUnescaped (§19.2.6.1) = alnum + `- _ . ! ~ * ' ( )`; encodeURI additionally keeps uriReserved+'#'.
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

/// §7.2.3 IsCallable — true iff `obj` is a function object (an AST closure, native, or bound function;
/// `kind == .function` covers all three). Used by the Promise machinery (executor / handlers / thenable
/// `then` must be callable).
pub fn isCallable(obj: *Object) bool {
    return obj.kind == .function;
}

/// §7.2.4 IsConstructor — does `obj` have a [[Construct]] internal method. Mirrors the guards in
/// `construct`: arrow functions, the Symbol/BigInt constructors (callable-but-not-`new`), and built-in
/// methods/statics (a native with no AST body that is not one of the genuine built-in constructors)
/// are NOT constructors. Ordinary functions / bound functions / classes ARE.
pub fn isConstructor(obj: *Object) bool {
    if (obj.kind != .function) return false;
    if (obj.call) |fd| {
        if (fd.is_arrow) return false; // arrows + methods/generators handled by the caller's body checks
        return true; // ordinary function / class / bound (M-subset: methods/generators are rare ctor targets)
    }
    // A native with no AST body: only the genuine built-in constructors qualify.
    if (obj.native == .none) return true; // a bound function wrapping a constructible target
    return switch (obj.native) {
        .error_ctor, .aggregate_error_ctor, .suppressed_error_ctor, .string_ctor, .object_ctor, .array_ctor, .function_ctor, .number_ctor, .boolean_ctor, .promise_ctor => true,
        else => false,
    };
}

/// Identity comparison of two Object-valued `Value`s (same `*Object`). False if either is not an object.
pub fn sameRef(a: Value, b: Value) bool {
    return a == .object and b == .object and a.object == b.object;
}

/// §27.2.5.4.1: a `then`/`catch` handler argument is used only if it is callable; a non-callable (incl.
/// undefined) handler means "use the default pass-through" (null). Reads `args[idx]` (absent → null).
fn handlerArg(args: []const Value, idx: usize) ?*Object {
    if (idx >= args.len) return null;
    const v = args[idx];
    if (v == .object and isCallable(v.object)) return v.object;
    return null;
}

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

/// A block needs its own declarative scope only if it lexically declares (let/const/function/class);
/// `var` is function-scoped and declaration-free blocks can reuse the parent env (hot-loop win).
/// §15.7: a ClassDeclaration creates a block-scoped lexical binding (like `let`), so a block whose
/// only declaration is a class still needs its own scope or the class name leaks to the parent.
fn blockNeedsScope(stmts: []const ast.Stmt) bool {
    for (stmts) |s| switch (s) {
        .declaration => |d| if (d.kind != .var_decl) return true, // let/const/using/await-using are lexical
        .func_decl, .class_decl => return true,
        else => {},
    };
    return false;
}

/// §14.2 / §ER: does this statement list lexically contain a `using` / `await using` declaration?
/// Only such a block sets up + runs a DisposeCapability at exit — every ordinary block skips the
/// dispose epilogue entirely (perf gate: ordinary block exit pays nothing). Shallow scan: a `using`
/// is only ever a direct child of the block's StatementList (nested blocks/loops run their own
/// epilogue), so we do not descend.
fn blockHasUsing(stmts: []const ast.Stmt) bool {
    for (stmts) |s| switch (s) {
        .declaration => |d| if (d.kind == .using_decl or d.kind == .await_using_decl) return true,
        else => {},
    };
    return false;
}
