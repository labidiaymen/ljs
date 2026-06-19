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
const bigint = @import("bigint.zig");
const module_mod = @import("module.zig");
const interp_property = @import("interp_property.zig");
const interp_module = @import("interp_module.zig");
const interp_iter = @import("interp_iter.zig");
const interp_stmt = @import("interp_stmt.zig");
const interp_expr = @import("interp_expr.zig");
const interp_ops = @import("interp_ops.zig");
const interp_async = @import("interp_async.zig");
const interp_collection = @import("interp_collection.zig");
const interp_arraylike = @import("interp_arraylike.zig");

// ECMA-262 abstract operations live in abstract_ops.zig; alias them so call sites read naturally.
const toBoolean = ops.toBoolean;

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
    pub inline fn loopHandles(comp_label: ?[]const u8, my_labels: []const []const u8) bool {
        const lbl = comp_label orelse return true; // unlabeled → innermost loop catches it
        for (my_labels) |m| if (std.mem.eql(u8, m, lbl)) return true;
        return false;
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

    pub fn tick(self: *Interpreter) EvalError!void {
        self.steps += 1;
        if (self.steps > self.step_limit) return EvalError.StepLimitExceeded;
    }

    // ── §16.2.1.6 module linking & evaluation ────────────────────────────────

    /// §16.2.1.6 Link + Evaluate a module graph rooted at `root` (whose `deps` were pre-resolved by
    /// the loader). Returns the root body's Completion. A SyntaxError surfaced during linking (an
    /// unresolvable / ambiguous import binding, §16.2.1.6.3 ResolveExport) is reported as an engine
    /// `throw` of a SyntaxError so the runner classifies a `negative: { phase: resolution }` test.
    pub fn runModule(self: *Interpreter, root: *module_mod.ModuleRecord, global: *Environment) EvalError!Completion {
        return interp_module.runModule(self, root, global);
    }

    // ── statements ──────────────────────────────────────────────────────────

    // `inline`: a trivial forwarder on the hottest recursion core — keep `self.evalStmt`/`self.evalExpr`
    // call sites a direct jump to the real body (no extra frame), matching pre-split inlining.
    pub inline fn evalStmt(self: *Interpreter, stmt: ast.Stmt, env: *Environment) EvalError!Completion {
        return interp_stmt.evalStmt(self, stmt, env);
    }

    /// §9.1.1.1 / §9.1.1.2 with-aware identifier resolution. Walks the scope chain consulting object
    /// Environment Records (the `with` binding objects, via `HasProperty`) and declarative records.
    /// ONLY used when `with_depth > 0`; the no-`with` path keeps the fast `env.lookup`. Returns the
    /// holding object (for a with binding), the declarative binding, or `.unresolved`.
    pub const IdRef = union(enum) { with_object: *Object, binding: *@import("environment.zig").Binding, unresolved };

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
        return interp_stmt.hoistLexicalNames(self, stmts, env);
    }

    /// §10.2.11 / §16.1.7 VarDeclaredNames instantiation: walk `stmts`, descending into nested
    /// non-function statements (blocks, if/while/do/for/for-in/for-of/try/with/switch/labeled bodies)
    /// but STOPPING at function/class boundaries, and create each `var` BoundName as an INITIALIZED
    /// `undefined` binding in `scope` — UNLESS already present (so a parameter, an earlier `var`, or a
    /// hoisted function of the same name is not clobbered). Mirrors the parser's `collectVarNames`.
    /// FunctionDeclarations are NOT collected (§14.2.2) — they are instantiated separately. Run once
    /// per Function/Script/eval entry, after `hoistLexicalNames`.
    pub fn hoistVarNames(self: *Interpreter, stmts: []const ast.Stmt, scope: *Environment) EvalError!void {
        return interp_stmt.hoistVarNames(self, stmts, scope);
    }

    pub const HeadBinding = struct { env: *Environment, completion: Completion = .{ .normal = .undefined } };

    // ── expressions ─────────────────────────────────────────────────────────

    pub inline fn evalExpr(self: *Interpreter, node: *const ast.Node, env: *Environment) EvalError!Completion {
        return interp_expr.evalExpr(self, node, env);
    }

    /// §15.7 PrivateGet — read PrivateName `key` from `base`'s own private slot. Accessing a private
    /// name on a non-object, or on an object lacking the brand, is a TypeError (§15.7 — the brand
    /// check). A private accessor invokes its getter with `this` = `base`; a getter-less accessor
    /// (set-only) is a TypeError on read.
    pub fn getPrivate(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        return interp_expr.getPrivate(self, base, key);
    }

    /// §15.7 PrivateSet — write PrivateName `key` on `base`'s own private slot. The brand must exist
    /// (TypeError otherwise). A private field is writable; a private method is read-only (TypeError on
    /// assignment); a private accessor invokes its setter with `this` = `base` (set-less → TypeError).
    pub fn setPrivate(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
        return interp_expr.setPrivate(self, base, key, value);
    }

    /// §10.2.2 [[Construct]] — instantiate `ctor` with already-evaluated `args`. Creates the new object
    /// (proto = `ctor.prototype`), runs base/derived class field + `super` ordering, invokes the
    /// constructor body with `this` = the new object, and returns an explicit object return if any.
    /// Shared by `new C()` and a bound function's [[Construct]] (§10.4.1.2). The instance's [[Prototype]]
    /// derives from `ctor` (i.e. newTarget === ctor); `Reflect.construct` uses `constructNT` for an
    /// explicit newTarget.
    pub fn construct(self: *Interpreter, ctor: *Object, args: []const Value) EvalError!Completion {
        return interp_expr.construct(self, ctor, args);
    }

    /// §10.2.2 [[Construct]] with an explicit [[NewTarget]] (§28.1.2 Reflect.construct). The instance's
    /// [[Prototype]] is read from `new_target.prototype` (an object, else %Object.prototype% per §10.1.13
    /// OrdinaryCreateFromConstructor), while the BODY still runs `ctor`. `new_target` must be a
    /// constructor (the caller validates IsConstructor).
    pub fn constructNT(self: *Interpreter, ctor: *Object, args: []const Value, new_target: *Object) EvalError!Completion {
        return interp_expr.constructNT(self, ctor, args, new_target);
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

    /// §7.1.19 ToPropertyKey ( argument ) — a Symbol stays a Symbol; an object is ToPrimitive(string)'d
    /// (which may itself yield a Symbol), then any non-symbol primitive is ToString'd. So a computed
    /// `[fn]` key uses the function's `toString` (consistent with `String(fn)`), not a raw fallback.
    pub fn toPropertyKey(self: *Interpreter, v: Value) EvalError!KeyResult {
        return interp_expr.toPropertyKey(self, v);
    }

    pub const ChainResult = struct {
        value: Value = .undefined,
        this_val: Value = .undefined, // receiver to use if the *next* link is a call
        short: bool = false, // the chain short-circuited (a `?.` base was nullish)
        completion: Completion = .{ .normal = .undefined },
        pub fn isAbrupt(self: ChainResult) bool {
            return self.completion.isAbrupt();
        }
    };

    /// Run a sequence of statements (a static block / function body) in `env`, returning the first
    /// abrupt completion (a `throw` propagates; `return`/`break`/`continue` are not produced at the
    /// top of a static block body in the M-subset). Used by §15.7.11 ClassStaticBlock evaluation.
    pub fn runBlockBody(self: *Interpreter, body: []const ast.Stmt, env: *Environment) EvalError!Completion {
        return interp_stmt.runBlockBody(self, body, env);
    }

    /// §15.1.5 ExpectedArgumentCount — the `length` value: the count of leading FormalParameters
    /// before the first one with a default initializer, a destructuring BindingPattern, or the rest
    /// element. (A simple identifier param with no default counts; the first non-simple param or the
    /// rest element stops the count.) `rest` is never counted (only stops the leading run).
    pub fn paramCount(params: []const ast.Param) f64 {
        return interp_expr.paramCount(params);
    }

    /// §20.2.4.1 install the `length` own data property — `{ writable:false, enumerable:false,
    /// configurable:true }`. Created at function-object creation (outside hot loops, so the two
    /// inserts cost nothing in the bench).
    pub fn setFunctionLength(obj: *Object, n: f64) std.mem.Allocator.Error!void {
        return interp_expr.setFunctionLength(obj, n);
    }

    /// §20.2.4.2 / §10.2.9 SetFunctionName — install the `name` own data property `{ writable:false,
    /// enumerable:false, configurable:true }`. `prefix` (when non-empty) is space-joined ahead of the
    /// name ("get"/"set"/"bound"). Names are interned in the realm arena so they outlive the call.
    pub fn setFunctionName(self: *Interpreter, obj: *Object, name: []const u8, prefix: []const u8) std.mem.Allocator.Error!void {
        return interp_expr.setFunctionName(self, obj, name, prefix);
    }

    /// §10.2.9 SetFunctionName for a Symbol key — the name is `"[" + description + "]"`, or `""` when
    /// the symbol has no description (`[[Description]]` is undefined). Interned in the realm arena.
    pub fn symbolPropName(self: *Interpreter, sym: *Symbol) std.mem.Allocator.Error![]const u8 {
        return interp_expr.symbolPropName(self, sym);
    }

    /// §8.4 NamedEvaluation — if `node` is an anonymous function/arrow/class expression and the
    /// evaluated `value` is the resulting (still-anonymous) function object, set its `name` to the
    /// binding/property name. Covers the common naming contexts: `var/let/const f = <anon>`,
    /// `f = <anon>` (identifier assignment), object-literal `{f: <anon>}`, and default initializers.
    /// A no-op for any non-anonymous-function value, so callers can apply it unconditionally.
    pub fn maybeSetAnonName(self: *Interpreter, node: *const ast.Node, value: Value, name: []const u8) std.mem.Allocator.Error!void {
        return interp_expr.maybeSetAnonName(self, node, value, name);
    }

    pub fn evalFunctionExpr(self: *Interpreter, f: *const ast.Function, env: *Environment) EvalError!Completion {
        return interp_expr.evalFunctionExpr(self, f, env);
    }

    /// §10.4.4.6 the realm's unique %ThrowTypeError% intrinsic, or null in a realm-less context.
    pub fn throwTypeErrorIntrinsic(self: *Interpreter) ?*Object {
        return interp_expr.throwTypeErrorIntrinsic(self);
    }

    pub fn callFunction(self: *Interpreter, func: *Object, args: []const Value, this_val: Value) EvalError!Completion {
        return interp_expr.callFunction(self, func, args, this_val);
    }

    /// §10.1.8 [[Get]]. Property access on null/undefined throws (§13.3); other primitives
    /// have no own properties in M1 (no boxing yet) → undefined.
    /// The first Proxy on `o`'s prototype chain (excluding `o` itself), or null. Used so an ordinary
    /// [[Get]]/[[HasProperty]] miss on the C-level chain still fires a Proxy proto's trap. Cheap: the
    /// chain is short and this is only consulted on a miss (the same chain `getProp` already walked).
    pub fn protoProxy(o: *Object) ?*object_mod.ProxyData {
        var p: ?*Object = o.prototype;
        while (p) |cur| : (p = cur.prototype) {
            if (cur.proxy) |pd| return pd;
        }
        return null;
    }

    pub fn getProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        return interp_property.getProperty(self, base, key);
    }

    /// §7.3.21 OrdinaryHasInstance — thin wrapper (used by the recursion in interp_expr and by the
    /// `instanceof` operator path). Returns `.normal = boolean` or an abrupt `.thrown` to propagate.
    pub fn ordinaryHasInstance(self: *Interpreter, c: Value, o: Value) EvalError!Completion {
        return interp_expr.ordinaryHasInstance(self, c, o);
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
        return interp_property.setProperty(self, base, key, value);
    }

    /// §13.3.3 / §7.1.19 ToPropertyKey-aware [[Get]] for a computed key (`a[k]`). A Symbol key routes
    /// to the symbol-keyed store (no ToString); any other key ToString's and takes the ordinary string
    /// path (the hot path, unchanged). Keeps the string get fast — the symbol branch is taken only when
    /// the key actually IS a Symbol.
    pub fn getPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!Completion {
        return interp_property.getPropertyV(self, base, key);
    }

    /// §13.3.3 ToPropertyKey-aware [[Set]] for a computed key (`a[k] = v`). Symbol → symbol store; else
    /// ToString + the ordinary string path.
    pub fn setPropertyV(self: *Interpreter, base: Value, key: Value, value: Value) EvalError!Completion {
        return interp_property.setPropertyV(self, base, key, value);
    }

    /// §7.1.19 ToPropertyKey, returning the coerced key as a primitive Value (a String, or a Symbol
    /// when the key is/ToPrimitive's to a Symbol). Used by read-then-write member operations (compound
    /// assignment, `++`/`--`) so a side-effecting `key.toString` runs EXACTLY ONCE — the resulting
    /// primitive is then passed to both `getPropertyV` and `setPropertyV` (which no-op on a primitive).
    pub fn coercePropertyKey(self: *Interpreter, key: Value) EvalError!Completion {
        return interp_property.coercePropertyKey(self, key);
    }

    /// §10.1.8 [[Get]] for a Symbol key — own/inherited symbol property (data or accessor). A primitive
    /// base with no symbol slot yields undefined; null/undefined throws (matching the string path).
    pub fn getSymbolProperty(self: *Interpreter, base: Value, key: *Symbol) EvalError!Completion {
        return interp_property.getSymbolProperty(self, base, key);
    }

    /// §10.1.9 [[Set]] for a Symbol key — invoke an inherited setter if present, else define an own
    /// symbol data property. Setting on null/undefined throws; on other primitives is a no-op.
    pub fn setSymbolProperty(self: *Interpreter, base: Value, key: *Symbol, value: Value) EvalError!Completion {
        return interp_property.setSymbolProperty(self, base, key, value);
    }

    // ── §7.1.1 ToPrimitive ───────────────────────────────────────────────────

    /// §7.1.1 the conversion hint for ToPrimitive — `default`/`number`/`string` (the spec strings
    /// passed to a `@@toPrimitive` method, and the method-name order for OrdinaryToPrimitive).
    pub const PrimHint = enum {
        default,
        number,
        string,
        pub fn str(self: PrimHint) []const u8 {
            return switch (self) {
                .default => "default",
                .number => "number",
                .string => "string",
            };
        }
    };

    /// A well-known Symbol identity (`Symbol.<name>`) held on the `Symbol` constructor. Null only in a
    /// realm-less unit eval (no `Symbol`). Used by the §ER dispose machinery (`dispose`/`asyncDispose`).
    pub fn wellKnownSymbol(self: *Interpreter, name: []const u8) ?*Symbol {
        return interp_ops.wellKnownSymbol(self, name);
    }

    /// §ER DisposeResources — at scope exit, dispose every resource pushed since `marker` in REVERSE
    /// (LIFO) order, threading `completion` (the body's completion). A disposer that throws while a
    /// throw completion is already pending is aggregated into a `SuppressedError { error, suppressed }`
    /// (the newest disposer error becomes `.error`, the prior pending completion becomes `.suppressed`);
    /// otherwise the disposer's throw simply replaces a previously-normal completion. The popped
    /// resources are removed from the stack. For an `await using`, the dispose result is awaited
    /// (via the body's await substrate when available). A normal `completion` and no throwing disposer
    /// returns `completion` unchanged.
    pub fn disposeFrom(self: *Interpreter, marker: usize, completion: Completion) EvalError!Completion {
        return interp_ops.disposeFrom(self, marker, completion);
    }

    /// §7.1.1 ToPrimitive ( input, hint ) — convert a value to a primitive. Primitives pass through
    /// unchanged (the hot path: no allocation, no method calls). For an Object: if it has an
    /// `@@toPrimitive` method, call it with the hint string and require a primitive result; otherwise
    /// run §7.1.1.1 OrdinaryToPrimitive with the effective hint (a `default` hint behaves as `number`).
    /// Returns the primitive Value, or an abrupt `.throw` completion on a TypeError / a thrown method.
    pub fn toPrimitive(self: *Interpreter, v: Value, hint: PrimHint) EvalError!Completion {
        return interp_ops.toPrimitive(self, v, hint);
    }

    /// §7.1.4 ToNumber in a coercion context: ToPrimitive (number hint) an object, then the pure
    /// numeric conversion. Primitives skip straight to the pure `toNumber` (hot path). A Symbol is a
    /// TypeError per §7.1.4 (surfaced here, not the pure helper's NaN).
    pub fn toNumberV(self: *Interpreter, v: Value) EvalError!Completion {
        return interp_ops.toNumberV(self, v);
    }

    /// §7.1.5 ToIntegerOrInfinity — ToNumber, then NaN→0, truncate toward zero, ±Inf preserved. Returns
    /// the integral (or ±Inf) value as a Number; propagates an abrupt ToNumber completion.
    pub fn toIntegerOrInfinity(self: *Interpreter, v: Value) EvalError!Completion {
        return interp_ops.toIntegerOrInfinity(self, v);
    }

    /// §7.1.17 ToString as a Completion — public wrapper for the built-in libraries (JSON, etc.):
    /// `.normal` holds the coerced string Value; a Symbol argument is an abrupt TypeError.
    pub fn toStringValuePub(self: *Interpreter, v: Value) EvalError!Completion {
        return interp_ops.toStringValuePub(self, v);
    }

    // ── §7.4 Iteration protocol (Symbol.iterator) ───────────────────────────────

    /// §7.3.12 HasProperty(O, ToString(i)) over an ARBITRARY object + its prototype chain — the
    /// generic-array-like counterpart of `arrayHasPropertyChain`. An array exotic checks its dense /
    /// sparse store first; every kind then falls back to the string-keyed chain walk.
    pub fn hasIndexChain(self: *Interpreter, o: *Object, i: usize) bool {
        return interp_arraylike.hasIndexChain(self, o, i);
    }

    /// §7.3.18 LengthOfArrayLike ( obj ) = ToLength(Get(obj, "length")). Clamped to [0, 2^53-1].
    /// Throwing (a Symbol/BigInt length → TypeError via ToNumber). Returns the length, or the abrupt
    /// completion to propagate. The Array exotic short-circuits to its tracked length.
    pub fn lengthOfArrayLike(self: *Interpreter, o: *Object) EvalError!Interpreter.LenOrAbrupt {
        return interp_arraylike.lengthOfArrayLike(self, o);
    }

    /// §7.3.4 Set(O, key, v, true) for an arbitrary object — Throw=true, so a failed [[Set]] (a
    /// getter-only accessor, a non-writable own data property, a new property on a non-extensible object,
    /// or a read-only String-wrapper index/length) raises a TypeError rather than silently no-op'ing
    /// (the in-place mutating Array methods rely on this). Emulates §10.1.9 OrdinarySet's success bit.
    pub fn setKeyThrow(self: *Interpreter, o: *Object, key: []const u8, v: Value) EvalError!Completion {
        return interp_arraylike.setKeyThrow(self, o, key, v);
    }

    /// §7.3.4 Set(O, ToString(i), v, true) for an arbitrary object. Array exotic uses the element store.
    pub fn setIndexThrow(self: *Interpreter, o: *Object, i: usize, v: Value) EvalError!Completion {
        return interp_arraylike.setIndexThrow(self, o, i, v);
    }

    /// §7.3.5 Set(O, "length", n, true) for an arbitrary object (the mutating methods' final length set).
    pub fn setLengthThrow(self: *Interpreter, o: *Object, n: usize) EvalError!Completion {
        return interp_arraylike.setLengthThrow(self, o, n);
    }

    /// §7.3.10 DeletePropertyOrThrow(O, ToString(i)) for an arbitrary object — a non-configurable own
    /// property (incl. a String-wrapper index) rejects → TypeError. Array exotic deletes a true hole.
    pub fn deleteIndexThrow(self: *Interpreter, o: *Object, i: usize) EvalError!Completion {
        return interp_arraylike.deleteIndexThrow(self, o, i);
    }

    /// §7.1.18 ToObject ( argument ) restricted to the cases the Array.prototype methods meet: an object
    /// passes through; `undefined`/`null` throw; a primitive boxes into the matching wrapper so its
    /// indexed reads (notably a String's chars / length) are observable as own properties.
    pub fn toObjectForArrayLike(self: *Interpreter, v: Value) EvalError!Interpreter.ObjOrAbrupt {
        return interp_arraylike.toObjectForArrayLike(self, v);
    }

    /// Public §7.1.4 ToNumber (throwing) for built-in modules — a Symbol/BigInt operand throws a
    /// TypeError, an object runs ToPrimitive(number). Used by Array methods whose arg coercion must be
    /// observable (e.g. `copyWithin(0, Symbol())` → TypeError).
    pub fn toNumberThrowing(self: *Interpreter, v: Value) EvalError!Completion {
        return interp_ops.toNumberThrowing(self, v);
    }

    /// Public §7.1.5 ToIntegerOrInfinity for built-in modules (e.g. `with` / `flat` index/depth args).
    pub fn toIntegerOrInfinityPub(self: *Interpreter, v: Value) EvalError!Completion {
        return interp_ops.toIntegerOrInfinityPub(self, v);
    }

    /// Public [[Get]] wrapper for built-in modules (e.g. `Array.from` reading `.length` / indices of
    /// an array-like). Same semantics as the internal `getProperty` (invokes getters, throws on
    /// null/undefined base).
    pub fn getProperty2(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        return interp_arraylike.getProperty2(self, base, key);
    }

    /// Public §20.1.3.6 Object.prototype.toString wrapper for built-in modules (Array.prototype.toString
    /// fallback when the object's `join` is not callable).
    pub fn objectPrototypeToString(self: *Interpreter, this_val: Value) EvalError!Completion {
        return interp_arraylike.objectPrototypeToString(self, this_val);
    }

    /// §7.3.20 Invoke ( V, P, argumentsList ) = Call(? GetV(V, P), V, args). Used by
    /// Array.prototype.toLocaleString (it invokes each element's own `toLocaleString`).
    pub fn invokeMethod(self: *Interpreter, v: Value, name: []const u8, args: []const Value) EvalError!Completion {
        return interp_arraylike.invokeMethod(self, v, name, args);
    }

    /// Does `value` expose a `[Symbol.iterator]` method (i.e. is it iterable)? Used by `Array.from` to
    /// choose the iterable branch over the array-like branch. A primitive String is iterable too, but
    /// the caller checks that separately.
    pub fn isArrayFromIterable(self: *Interpreter, value: Value) EvalError!bool {
        return interp_arraylike.isArrayFromIterable(self, value);
    }

    /// §23.1.2.1 Array.from iterable branch (steps 6.b–6.h): step the iterator, apply `map_fn` per
    /// element AS WE GO, and CreateDataProperty onto `out` at the running index. An abrupt completion
    /// from `next`/`map_fn` triggers IteratorClose then propagates — so an infinite iterator whose
    /// mapFn throws on the first element terminates immediately (no draining → no OOM). On success
    /// `out.array_length` is the count. Returns the abrupt completion if any, else normal/undefined.
    pub fn arrayFromIterate(self: *Interpreter, items: Value, out: *Object, map_fn: ?*Object, this_arg: Value) EvalError!Completion {
        return interp_arraylike.arrayFromIterate(self, items, out, map_fn, this_arg);
    }

    /// The realm's well-known `Symbol.iterator` identity (the same value held on the `Symbol`
    /// constructor), used by GetIterator. Null only in a realm-less unit-test eval (no `Symbol`).
    pub fn wellKnownIterator(self: *Interpreter) ?*Symbol {
        return interp_iter.wellKnownIterator(self);
    }

    pub const IterResult = union(enum) { iterator: *Object, abrupt: Completion };

    /// §7.4.2 GetIterator ( obj ) — read `obj[Symbol.iterator]`, call it with `this` = obj, and
    /// require the result to be an object (the iterator). Returns the iterator object, or an abrupt
    /// completion (TypeError) if the value is not iterable. Null `iter_sym` (realm-less) → not iterable.
    pub fn getIterator(self: *Interpreter, obj: Value) EvalError!IterResult {
        return interp_iter.getIterator(self, obj);
    }

    /// The realm's well-known `Symbol.asyncIterator` identity (held on the `Symbol` constructor).
    pub fn wellKnownAsyncIterator(self: *Interpreter) ?*Symbol {
        return interp_iter.wellKnownAsyncIterator(self);
    }

    /// §7.4.3 GetIterator ( obj, async ) — read `obj[Symbol.asyncIterator]`; if present, call it (the
    /// result is the async iterator). If ABSENT, fall back to the SYNC iterator (`obj[Symbol.iterator]`)
    /// and wrap it in an AsyncFromSyncIterator (§27.1.4.1 CreateAsyncFromSyncIterator) so `for await`
    /// can drive a sync iterable. A value with neither → TypeError.
    pub fn getAsyncIterator(self: *Interpreter, obj: Value) EvalError!IterResult {
        return interp_iter.getAsyncIterator(self, obj);
    }

    pub const StepResult = union(enum) { value: Value, done, abrupt: Completion };

    /// §7.4.4 IteratorStep + §7.4.5 IteratorValue — call `iterator.next()`, require an object result,
    /// and return its `value` (or `.done` when `done` is truthy). An abrupt completion from `next` (or
    /// a non-object result) propagates as `.abrupt`.
    pub fn iteratorStep(self: *Interpreter, iterator: *Object) EvalError!StepResult {
        return interp_iter.iteratorStep(self, iterator);
    }

    /// §7.4.11 IteratorClose ( iterator, completion ) — best-effort: call `iterator.return()` if it
    /// exists, ignoring its result (the original completion is what matters). Called on an early exit
    /// from a for-of loop (`break`/`return`/`throw`). A missing/non-callable `return` is a no-op.
    pub fn iteratorClose(self: *Interpreter, iterator: *Object) EvalError!void {
        return interp_iter.iteratorClose(self, iterator);
    }

    /// §7.4.11 IteratorClose for a NORMAL (non-throw) incoming completion — the iterator is being
    /// closed early on `break` / loop-exiting `continue` / `return`, so a thrown `return()` (or a
    /// non-Object `return()` result) MUST propagate (steps 5–6), unlike the throw-completion case
    /// (`iteratorClose`, step 4, which swallows). Returns `.normal` on a clean close, else the abrupt
    /// completion to propagate. GetMethod semantics: undefined/null `return` → no-op; non-callable →
    /// TypeError (§7.3.10).
    pub fn iteratorCloseChecked(self: *Interpreter, iterator: *Object) EvalError!Completion {
        return interp_iter.iteratorCloseChecked(self, iterator);
    }

    /// §7.4.1 GetIterator + drain — materialize an iterable `value` into a slice of its yielded values
    /// via the full Symbol.iterator protocol. Used by spread / array destructuring (which need the
    /// whole sequence up front). Arrays/Strings have native iterators (fast), but ANY object with a
    /// `[Symbol.iterator]` returning a `next`-having object works. A non-iterable → abrupt TypeError.
    pub fn iterateToList(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!Completion {
        return interp_iter.iterateToList(self, value, out);
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
    pub const ArrayDestr = union(enum) {
        /// Plain Array fast path: a cursor over the backing `elements` (no iterator object exists).
        fast: struct { items: []const Value, idx: usize = 0 },
        /// General iterable: a §7.4 iterator record. `done` mirrors IteratorRecord.[[Done]].
        iter: struct { iterator: *Object, done: bool = false },

        pub fn isDone(self: ArrayDestr) bool {
            return switch (self) {
                .fast => |f| f.idx >= f.items.len,
                .iter => |it| it.done,
            };
        }
    };

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

    pub fn runGeneratorBody(self: *Interpreter, gen: *object_mod.Generator) EvalError!Completion {
        return interp_async.runGeneratorBody(self, gen);
    }

    /// How the consumer resumed a parked `yield` — the resume kind (`.next`/`.return`/`.throw`) plus
    /// the value it carried. `abandon` is set when realm teardown woke the body to unwind it.
    pub const Resumption = struct { kind: object_mod.ResumeKind, value: Value, abandon: bool };

    pub const IterStep = struct { value: Value, done: bool };
    pub const CallStepResult = union(enum) { result: IterStep, abrupt: Completion };

    /// Realm teardown: any generator left suspended (never fully consumed) has a body thread parked on
    /// `resume_gen`. Signal each to abandon and resume it so the thread unwinds and we can join it —
    /// otherwise the OS thread would linger past the realm. Best-effort (a body that ignores `abandon`
    /// would still be joined once it next yields/completes). Runs on the MAIN interpreter at end-of-run.
    pub fn cleanupGenerators(self: *Interpreter) void {
        return interp_async.cleanupGenerators(self);
    }

    // ── §27.2 Promise + §9.5 Job (microtask) queue + §27.7 async functions ───────
    //
    // A Promise object carries a PromiseData slot (state / result / reaction lists). `then` queues a
    // reaction; on settlement each reaction becomes a Job on the realm queue. The engine drains the
    // queue once the synchronous stack is empty (`drainJobs`, step-bounded — no hangs). An async
    // function reuses the GENERATOR thread substrate: its body runs on a std.Thread, suspending at each
    // `await` via the ping-pong handoff (`Generator.is_async = true`); the awaited value is carried out,
    // the caller registers fulfill/reject reactions on it, and the reaction Jobs resume the body thread.

    /// §27.2.3.1 CreatePromise / NewPromiseCapability — a fresh pending Promise object (proto =
    /// %PromisePrototype%) with empty reaction lists.
    pub fn newPromise(self: *Interpreter) EvalError!*Object {
        return interp_async.newPromise(self);
    }

    /// §9.5 drain the Job (microtask) queue to completion: while non-empty, dequeue (FIFO) and run the
    /// front job; each job may enqueue more. Bounded by the interpreter step limit — a runaway microtask
    /// loop (e.g. a promise that re-schedules itself forever) terminates via StepLimitExceeded rather
    /// than hanging. Runs on the MAIN interpreter after the synchronous script completes. A job that
    /// throws unhandled is swallowed (an unhandled rejection is not a host error — there is no host).
    pub fn drainJobs(self: *Interpreter) EvalError!void {
        return interp_async.drainJobs(self);
    }

    // ── §27.7 async functions (thread-suspended body, await ↔ promise reactions) ─

    /// After an async body handoff: an `await` transfer (kind `.yield`) registers fulfill/reject
    /// reactions on the awaited promise that will resume the body; a terminal `.ret`/`.throw` resolves
    /// /rejects the function's promise and joins the thread (§27.7.5.2).
    pub fn settleAsyncTransfer(self: *Interpreter, gen: *object_mod.Generator) EvalError!void {
        return interp_async.settleAsyncTransfer(self, gen);
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

    /// %AsyncFromSyncIteratorPrototype% — the proto of an AsyncFromSyncIterator wrapper object.
    pub fn asyncFromSyncProto(self: *Interpreter) ?*Object {
        return interp_async.asyncFromSyncProto(self);
    }

    // ── §27.1.4 AsyncFromSyncIterator ────────────────────────────────────────────

    // ── §27.2.4 Promise combinators (all / allSettled / any / race) ──────────────
    //
    // Each reads the iterable up front via §7.4 GetIterator+drain (`iterateToList`), wraps each element
    // with PromiseResolve, and registers reactions through the existing Job machinery (`performPromiseThen`).
    // `all`/`allSettled`/`any` share `CombinatorState` (a result array + a [[Remaining]] counter started
    // at 1 and decremented once per settled element + once after the loop, §27.2.4.1.1, so the empty-input
    // case settles synchronously after the loop). `race` needs no shared state — it forwards each element's
    // settlement straight to the result promise (first-settled wins; later settlements are no-ops).

    pub const CombinatorKind = enum { all, all_settled, any, race };

    /// §13.5.1.2 / §10.1.10 [[Delete]] — remove the own property `key` from `base`. A non-configurable
    /// own property is NOT deleted and yields `false` (so `delete` on a sealed/frozen property reports
    /// correctly); an absent property yields `true`. On a primitive base, deletion is a no-op → true.
    pub fn deleteProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
        return interp_property.deleteProperty(self, base, key);
    }

    /// Result of a boolean-returning ordinary internal method (define/setProto/preventExt): a
    /// success boolean, or an abrupt Completion (a Proxy trap throw). Named so the two key-typed
    /// `ordinaryDefineOwnProperty*` overloads share one return type (unifiable in a `switch`).
    pub const BoolOrAbrupt = union(enum) { ok: bool, abrupt: Completion };
    pub const PVOrAbrupt = union(enum) { pv: ?object_mod.PropertyValue, abrupt: Completion };
    /// Result of [[GetPrototypeOf]] — the prototype (object or null), or an abrupt Completion (a
    /// Proxy `getPrototypeOf` trap throw). Named so interpreter.zig + interp_property.zig agree on type.
    pub const ProtoOrAbrupt = union(enum) { proto: ?*Object, abrupt: Completion };
    /// Result of [[IsExtensible]] — a boolean, or an abrupt Completion (a Proxy trap throw).
    pub const ExtOrAbrupt = union(enum) { ext: bool, abrupt: Completion };
    /// Result of [[OwnPropertyKeys]] — the own keys slice, or an abrupt Completion (a Proxy trap throw).
    pub const KeysOrAbrupt = union(enum) { keys: []Value, abrupt: Completion };
    pub const LenOrAbrupt = union(enum) { len: usize, abrupt: Completion };
    pub const ObjOrAbrupt = union(enum) { obj: *Object, abrupt: Completion };
    pub const DescOrAbrupt = union(enum) { desc: object_mod.Descriptor, abrupt: Completion };
    pub const ListOrAbrupt = union(enum) { list: []const Value, abrupt: Completion };
    pub const ArrOrAbrupt = union(enum) { array: *Object, abrupt: Completion };
    pub const DriverOrAbrupt = union(enum) { driver: ArrayDestr, abrupt: Completion };
    pub const SetRecOrAbrupt = union(enum) { rec: SetRecord, abrupt: Completion };
    pub const IterObjOrAbrupt = union(enum) { iter: *Object, abrupt: Completion };

    // ── §10.1 Ordinary internal methods on a target *Object (used by the Proxy forwarding path and
    //    by the proxy-aware Object/Reflect routing). Each is Array/String-exotic aware and proxy-aware:
    //    when the target is itself a Proxy these route through its handler trap. ─────────────────────

    /// §10.1.5 / §10.4.2.1 [[GetOwnProperty]] for a string key → the stored attributes (data/accessor),
    /// or null when absent. Array indices / `length` and String-exotic indices yield synthetic
    /// descriptors. Routes through the proxy trap when `o` is a Proxy.
    pub fn ordinaryGetOwnProperty(self: *Interpreter, o: *Object, key: []const u8) EvalError!PVOrAbrupt {
        return interp_property.ordinaryGetOwnProperty(self, o, key);
    }

    /// §10.1.5 [[GetOwnProperty]] for a Symbol key → stored attributes or null. Proxy-aware.
    pub fn ordinaryGetOwnPropertySymbol(self: *Interpreter, o: *Object, key: *Symbol) EvalError!PVOrAbrupt {
        return interp_property.ordinaryGetOwnPropertySymbol(self, o, key);
    }

    /// §10.1.6 / §10.4.2.1 [[DefineOwnProperty]] → boolean. Proxy-aware; Array-index aware. For an
    /// ordinary object, delegates to `Object.defineProperty`. (Array `length` keeps the store path.)
    pub fn ordinaryDefineOwnProperty(self: *Interpreter, o: *Object, key: []const u8, d: object_mod.Descriptor) EvalError!BoolOrAbrupt {
        return interp_property.ordinaryDefineOwnProperty(self, o, key, d);
    }

    pub fn ordinaryDefineOwnPropertySymbol(self: *Interpreter, o: *Object, key: *Symbol, d: object_mod.Descriptor) EvalError!BoolOrAbrupt {
        return interp_property.ordinaryDefineOwnPropertySymbol(self, o, key, d);
    }

    /// §10.1.1 [[GetPrototypeOf]] → the prototype (object or null). Proxy-aware.
    pub fn ordinaryGetPrototypeOf(self: *Interpreter, o: *Object) EvalError!ProtoOrAbrupt {
        return interp_property.ordinaryGetPrototypeOf(self, o);
    }

    /// §10.1.2 [[SetPrototypeOf]] → boolean. Proxy-aware.
    pub fn ordinarySetPrototypeOf(self: *Interpreter, o: *Object, proto: ?*Object) EvalError!BoolOrAbrupt {
        return interp_property.ordinarySetPrototypeOf(self, o, proto);
    }

    /// §10.1.3 [[IsExtensible]] → boolean. Proxy-aware.
    pub fn ordinaryIsExtensible(self: *Interpreter, o: *Object) EvalError!ExtOrAbrupt {
        return interp_property.ordinaryIsExtensible(self, o);
    }

    /// §10.1.4 [[PreventExtensions]] → boolean. Proxy-aware.
    pub fn ordinaryPreventExtensions(self: *Interpreter, o: *Object) EvalError!BoolOrAbrupt {
        return interp_property.ordinaryPreventExtensions(self, o);
    }

    /// §10.1.11 [[OwnPropertyKeys]] → the own keys as an allocated `[]Value` (strings then symbols for
    /// an ordinary object; for an Array: indices, `length`, string keys, symbols). Proxy-aware.
    pub fn ordinaryOwnKeys(self: *Interpreter, o: *Object) EvalError!KeysOrAbrupt {
        return interp_property.ordinaryOwnKeys(self, o);
    }

    /// Map a `bigint.Error` to the right JS exception (or propagate OutOfMemory).
    pub fn bigintError(self: *Interpreter, e: bigint.Error) EvalError!Completion {
        return interp_ops.bigintError(self, e);
    }

    pub fn throwError(self: *Interpreter, kind: []const u8, msg: []const u8) EvalError!Completion {
        const err = try Object.create(self.arena, self.errorProto(kind));
        err.error_data = true; // §20.5 [[ErrorData]] → §20.1.3.6 "Error" tag
        try err.set("name", .{ .string = kind });
        try err.set("message", .{ .string = msg });
        return .{ .throw = .{ .object = err } };
    }

    pub fn errorProto(self: *Interpreter, kind: []const u8) ?*Object {
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
    pub fn wellKnownSpecies(self: *Interpreter) ?*Symbol {
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
        return interp_arraylike.arraySpeciesCreate(self, original, length);
    }

    /// §10.4.2.2 ArrayCreate(length): a fresh plain Array exotic of [[Length]] `length` (no eager fill —
    /// a length-only grow is sparse), proto-linked to %Array.prototype%. The default ArraySpeciesCreate
    /// result. A length above 2^32-1 → RangeError (step 1).
    pub fn newArray(self: *Interpreter, length: usize) EvalError!Completion {
        return interp_arraylike.newArray(self, length);
    }

    /// §23.1.2.1/.3 the `A` target for Array.from / Array.of: `IsConstructor(C) ? Construct(C, «len») :
    /// ArrayCreate(len)`. `C` is the `this` value of the static call (so `Array.from.call(Ctor, …)` uses
    /// `Ctor`). A non-constructor `this` (e.g. the plain `Array.from(…)` where `this` is the Array ctor,
    /// or an arbitrary non-ctor receiver) → a plain Array. The result is populated by the caller via
    /// CreateDataPropertyOrThrow, so a constructor that returns a non-extensible / locked object throws.
    pub fn arrayCreateFromCtor(self: *Interpreter, this_val: Value, length: usize) EvalError!Completion {
        return interp_arraylike.arrayCreateFromCtor(self, this_val, length);
    }

    /// §7.3.7 CreateDataPropertyOrThrow ( O, P, V ) — define an own data property
    /// `{ value:V, writable:true, enumerable:true, configurable:true }`, throwing a TypeError if the
    /// definition is rejected. For an Array exotic at an integer index this is the array [[Set]] with
    /// Throw=true: a frozen array (non-writable elements) or a non-extensible array gaining a NEW index
    /// rejects → TypeError. For a generic object (a non-Array species result) it routes through
    /// [[DefineOwnProperty]] so a configurable non-writable existing prop is redefined writable.
    /// Returns `.normal = undefined` on success, or the abrupt `.thrown` completion (caller propagates).
    pub fn createDataPropertyOrThrow(self: *Interpreter, target: *Object, index: usize, value: Value) EvalError!Completion {
        return interp_arraylike.createDataPropertyOrThrow(self, target, index, value);
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
    pub fn toPropertyDescriptor(self: *Interpreter, attrs: Value) EvalError!Interpreter.DescOrAbrupt {
        return interp_arraylike.toPropertyDescriptor(self, attrs);
    }

    /// §7.3.23 own ENUMERABLE string keys of `value` — a thin wrapper kept on the Interpreter so JSON
    /// and other built-ins reach the helper now living in builtin_object.
    pub fn ownEnumerableKeys(self: *Interpreter, value: Value, out: *std.ArrayListUnmanaged(Value)) EvalError!?Completion {
        return interp_arraylike.ownEnumerableKeys(self, value, out);
    }

    /// §7.1.19 ToPropertyKey then ToString — a thin wrapper kept on the Interpreter so Object/Reflect
    /// reach the helper now living in builtin_reflect.zig.
    pub fn toPropertyKeyString(self: *Interpreter, key: Value) EvalError![]const u8 {
        return interp_arraylike.toPropertyKeyString(self, key);
    }
    // ── §21.3 Math ──────────────────────────────────────────────────────────

    /// §21.3.2.27 Math.random — the next xorshift64* draw mapped to [0,1). A fixed-seed PRNG (no host
    /// entropy in this sandbox; the engine is deterministic). Uses the top 53 bits for a uniform double.
    pub fn randomNext(self: *Interpreter) f64 {
        return interp_arraylike.randomNext(self);
    }

    /// §7.3.12 HasProperty for a Value key (string or symbol) — proto-chain walk (the `in` semantics).
    /// §7.3.12 HasProperty as a Completion (so a Proxy `has` trap that throws/revokes can propagate).
    /// Use this wherever the result feeds a JS-observable operation (`in`, `Reflect.has`).
    pub fn hasPropertyVC(self: *Interpreter, base: Value, key: Value) EvalError!Completion {
        return interp_arraylike.hasPropertyVC(self, base, key);
    }

    pub fn hasPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!bool {
        return interp_arraylike.hasPropertyV(self, base, key);
    }

    // ── §20.2.3 Function.prototype methods ──────────────────────────────────

    /// §7.3.18 CreateListFromArrayLike (§20.2.3.1 step 2): null/undefined → empty list; an Array →
    /// its elements; any other object → its `0..length-1` indexed values (M-subset: array-likes via
    /// `.length`); a non-object non-nullish argArray → TypeError.
    pub fn createListFromArrayLike(self: *Interpreter, v: Value) EvalError!Interpreter.ListOrAbrupt {
        return interp_arraylike.createListFromArrayLike(self, v);
    }

    // ── §19.2 global function intrinsics ─────────────────────────────────────────

    pub const UriKind = enum { uri, component };

    // ── §21.1.3 Number.prototype methods ─────────────────────────────────────────

    /// §24.2.1.2 Set Record — a set-LIKE argument (`other`), duck-typed via `size`/`has`/`keys`. NOT
    /// necessarily a real Set, so the algebra below must call `has`/`keys` dynamically (observably).
    pub const SetRecord = struct { obj: Value, size: f64, has: *Object, keys: *Object };

    /// §24.2.3 union/intersection/difference/symmetricDifference/isSubsetOf/isSupersetOf/isDisjointFrom.
    /// `this_coll` is the already-brand-checked Set; `args[0]` is the set-like `other`.
    pub fn setAlgebra(self: *Interpreter, name: []const u8, this_coll: *object_mod.Collection, args: []const Value) EvalError!Completion {
        return interp_collection.setAlgebra(self, name, this_coll, args);
    }

    /// §7.1.17 ToString — delegates to the abstract operation (handles Array join). Used for property
    /// keys and engine-internal stringification, where a Symbol never reaches it (computed keys route
    /// to the symbol store first). The user-facing string COERCION contexts (template / `+`) use
    /// `toStringCoerce`, which throws on a Symbol per spec.
    pub fn toString(self: *Interpreter, v: Value) EvalError![]const u8 {
        return interp_ops.toString(self, v);
    }

    /// §7.1.17 ToString — the FULL throwing form (ToPrimitive(string) on an object, TypeError on a
    /// Symbol). Public so the string library (§22.1.3) can coerce `this`/arguments with the observable
    /// abrupt completions the spec mandates (e.g. `"".endsWith(Symbol())` → TypeError). Returns the
    /// string, or the abrupt completion when coercion throws.
    pub fn toStringThrowing(self: *Interpreter, v: Value) EvalError!Completion {
        return interp_ops.toStringThrowing(self, v);
    }

    pub const CoerceResult = union(enum) { string: []const u8, abrupt: Completion };
};

// ── §19.2 global-function lexical helpers ────────────────────────────────────

/// §7.2.3 IsCallable — true iff `obj` is a function object (an AST closure, native, or bound function;
/// `kind == .function` covers all three). Used by the Promise machinery (executor / handlers / thenable
/// `then` must be callable).
pub fn isCallable(obj: *Object) bool {
    // §10.5: a Proxy has a [[Call]] iff its target does. A revoked proxy keeps whatever it had at
    // creation (IsCallable reads the slot presence, not revocation — revocation throws on invocation).
    if (obj.proxy) |pd| return isCallable(pd.target);
    return obj.kind == .function;
}

/// §7.2.4 IsConstructor — does `obj` have a [[Construct]] internal method. Mirrors the guards in
/// `construct`: arrow functions, the Symbol/BigInt constructors (callable-but-not-`new`), and built-in
/// methods/statics (a native with no AST body that is not one of the genuine built-in constructors)
/// are NOT constructors. Ordinary functions / bound functions / classes ARE.
pub fn isConstructor(obj: *Object) bool {
    // §10.5: a Proxy has a [[Construct]] iff its target is a constructor.
    if (obj.proxy) |pd| return isConstructor(pd.target);
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
pub fn handlerArg(args: []const Value, idx: usize) ?*Object {
    if (idx >= args.len) return null;
    const v = args[idx];
    if (v == .object and isCallable(v.object)) return v.object;
    return null;
}

/// §13.15.2: should a LogicalAssignment write, given the operator and the target's current value?
///   • `&&=` (and_)      — only when the current value is truthy.
///   • `||=` (or_)       — only when the current value is falsy.
///   • `??=` (coalesce)  — only when the current value is null/undefined (§13.13 nullish guard).
pub fn shouldAssign(op: ast.LogicalOp, cur: Value) bool {
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
pub fn blockNeedsScope(stmts: []const ast.Stmt) bool {
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
pub fn blockHasUsing(stmts: []const ast.Stmt) bool {
    for (stmts) |s| switch (s) {
        .declaration => |d| if (d.kind == .using_decl or d.kind == .await_using_decl) return true,
        else => {},
    };
    return false;
}
