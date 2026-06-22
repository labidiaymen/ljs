//! Engine entry point: source text → observable result. Wires lexer → parser → interpreter
//! and maps outcomes to an EvaluationResult the CLI and the Test262 harness consume.
const std = @import("std");
const Value = @import("value.zig").Value;
const Parser = @import("parser.zig").Parser;
const parser_mod = @import("parser.zig");

/// Build a `line:col` SyntaxError message from the parser's last-failure position (set in
/// `parseProgram`'s error unwind). Falls back to the bare error name if formatting fails.
fn syntaxMsg(arena: std.mem.Allocator, src: []const u8, e: anyerror) []const u8 {
    const lx = parser_mod.last_error_lexeme;
    // Only use the lexeme if it is provably a slice fully WITHIN `src` (for escaped-identifier / EOF
    // tokens the lexeme can be a decoded/arena value that doesn't point into the source — reading it as
    // a source slice would be unsafe). Otherwise fall back to the bare error name.
    const base = @intFromPtr(src.ptr);
    const lp = @intFromPtr(lx.ptr);
    if (lx.len == 0 or src.len == 0 or lp < base or lp + lx.len > base + src.len) return @errorName(e);
    const lc = parser_mod.lineColOf(src, lp - base);
    return std.fmt.allocPrint(arena, "{s} near '{s}' (line {d}:{d})", .{ @errorName(e), lx, lc.line, lc.col }) catch @errorName(e);
}
const Interpreter = @import("interpreter.zig").Interpreter;
const Environment = @import("environment.zig").Environment;
const builtins = @import("builtins.zig");

/// ECMA-262 distinguishes strict and sloppy mode. The M0 expression subset has no
/// observable difference yet; the parameter is threaded now so the harness can run both.
pub const RunMode = enum { sloppy, strict };

pub const EvaluationResult = union(enum) {
    normal: Value,
    thrown: Value,
    syntax_error: []const u8,
    step_limit,
};

pub const default_step_limit: u64 = 10_000_000;

/// The classified result of a Test262 `[async]` test (driven via the runner-injected `$DONE`). The
/// runner maps this to pass/fail. Not part of ECMA-262 — the conformance harness's async contract.
pub const AsyncTestResult = union(enum) {
    /// `$DONE` was called with no/undefined/falsy argument → the async test passed.
    async_pass,
    /// `$DONE` was called with a truthy argument (the failure value, stringified) → async fail.
    async_fail: []const u8,
    /// `$DONE` was NEVER called (after draining all microtasks) → the async test did not report → fail.
    never_done,
    /// The script failed to parse.
    syntax_error: []const u8,
    /// The step watchdog fired (runaway sync code OR microtask loop) → fail.
    step_limit,
    /// The synchronous script threw before reaching/arming the async machinery → fail.
    sync_throw: Value,
};

/// Evaluate a Test262 `[async]` test: inject a native `$DONE(err)` global (the async completion
/// callback) plus its shared sink, run the script, DRAIN the microtask Job queue (so async-function
/// continuations and Promise reactions complete), then classify via whether/how `$DONE` was called.
/// This is the engine surface the conformance runner uses for `[async]` tests (it no longer skips
/// them). Deterministic — no real timers; the drain is step-bounded so a never-settling promise or a
/// runaway microtask loop terminates rather than hangs.
pub fn evaluateAsyncTest(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64) error{OutOfMemory}!AsyncTestResult {
    return evaluateAsyncTestL(arena, source, mode, step_limit, null, "");
}

/// §13.3.10 like `evaluateAsyncTest`, but with the optional minimal harness module loader (+ the
/// test's referrer key) threaded in so a `flags:[async]` test that does `await import('./fixture.js')`
/// can resolve + load the fixture. The dynamic-import bucket is overwhelmingly async tests, so this is
/// the primary entry for it. `loader == null` reproduces the loader-less async-test behavior.
pub fn evaluateAsyncTestL(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64, loader: ?ModuleLoader, referrer_key: []const u8) error{OutOfMemory}!AsyncTestResult {
    const interp_mod = @import("interpreter.zig");
    const obj_mod = @import("object.zig");
    const program = Parser.parseMode(arena, source, mode == .strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = syntaxMsg(arena, source, e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    // Inject the native `$DONE` global (overriding any harness-defined one for the common case where
    // the test references `$DONE` directly). It records completion on the shared sink the runner reads.
    const done_sink = arena.create(interp_mod.AsyncDone) catch return error.OutOfMemory;
    done_sink.* = .{};
    const done_fn = obj_mod.Object.createNative(arena, .test_done, "$DONE") catch return error.OutOfMemory;
    {
        const fp = global.lookup("Function");
        if (fp) |b| if (b.value == .object) {
            if (b.value.object.get("prototype")) |pv| if (pv == .object) {
                done_fn.prototype = pv.object;
            };
        };
    }
    global.declare("$DONE", .{ .object = done_fn }, true, true) catch return error.OutOfMemory;
    // §19.3 also install `$DONE` as an OWN property of the reified global object, so the harness's
    // `asyncTest` — which gates on `Object.prototype.hasOwnProperty.call(globalThis, "$DONE")` — sees it
    // (the async flag is signalled by `$DONE`'s presence on globalThis, per asyncHelpers.js).
    if (global.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        gb.value.object.defineData("$DONE", .{ .object = done_fn }, true, false, true) catch return error.OutOfMemory;
    };
    var gen_registry: std.ArrayListUnmanaged(*obj_mod.Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(obj_mod.Job) = .empty;
    var mcache: std.StringHashMapUnmanaged(*module_mod.ModuleRecord) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue, .async_done = done_sink };
    if (loader) |l| {
        interp.module_loader = l;
        interp.module_cache = &mcache;
        interp.host_referrer_key = referrer_key;
    }
    // §9.4.2 GetThisBinding: the global environment's `this` is the global object (in both strict and
    // sloppy mode), so the top-level Script body runs with `this` = globalThis.
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;
    const completion = interp.run(program, global) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // A synchronous throw before the async machinery is armed → the test failed synchronously (unless
    // it already reported via $DONE in a prior statement — the sink check below handles that order).
    if (completion == .throw and !done_sink.called) {
        interp.cleanupGenerators();
        return .{ .sync_throw = completion.throw };
    }
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    if (!done_sink.called) return .never_done;
    if (done_sink.failed) return .{ .async_fail = done_sink.message };
    return .async_pass;
}

pub fn evaluate(arena: std.mem.Allocator, source: []const u8, mode: RunMode) error{OutOfMemory}!EvaluationResult {
    return evaluateWithLimit(arena, source, mode, default_step_limit);
}

const module_mod = @import("module.zig");

/// §16.2.1.6 HostResolveImportedModule loader interface — defined in `module.zig` (a leaf module)
/// so the interpreter can also hold a loader without an engine↔interpreter import cycle; re-exported
/// here for the runner + CLI that constructed these via `ljs.ModuleLoader`.
pub const ModuleLoader = module_mod.ModuleLoader;
pub const ResolvedSource = module_mod.ResolvedSource;

/// Parse + recursively load a module graph rooted at `root_key`/`root_source`, caching each module
/// by resolved key (so a diamond / self-import is shared and a cycle terminates). Returns the root
/// record, or a parse SyntaxError (the §16.2 parse goal) for any module that fails to parse.
fn loadGraph(
    arena: std.mem.Allocator,
    loader: ModuleLoader,
    cache: *std.StringHashMapUnmanaged(*module_mod.ModuleRecord),
    root_key: []const u8,
    root_source: []const u8,
) error{ OutOfMemory, SyntaxError }!*module_mod.ModuleRecord {
    if (cache.get(root_key)) |m| return m;
    const program = Parser.parseModule(arena, root_source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SyntaxError,
    };
    const rec = arena.create(module_mod.ModuleRecord) catch return error.OutOfMemory;
    rec.* = .{ .key = root_key, .program = program };
    cache.put(arena, root_key, rec) catch return error.OutOfMemory;
    var deps: std.ArrayListUnmanaged(*module_mod.ModuleRecord) = .empty;
    for (program.requested_modules) |spec| {
        const resolved = loader.resolve(loader.ctx, root_key, spec) orelse return error.SyntaxError;
        const dep = try loadGraph(arena, loader, cache, resolved.key, resolved.source);
        deps.append(arena, dep) catch return error.OutOfMemory;
    }
    rec.deps = deps.items;
    return rec;
}

/// §16.2.1.6 Evaluate a `[module]` Test262 test: install the harness `prelude` (sta.js + assert.js +
/// includes) as a SCRIPT in a fresh realm's global (so `assert`, `$DONOTEVALUATE`, … are globals),
/// then parse + load + Link + Evaluate the module graph rooted at `root_source` (resolved key
/// `root_key`), drain the Job queue (top-level await), and map the outcome. A parse-phase SyntaxError
/// in ANY module → `.syntax_error`; an unresolved import / ambiguous export → a thrown SyntaxError
/// (resolution phase). The realm + globals persist for the module env's parent chain.
pub fn evaluateModule(
    arena: std.mem.Allocator,
    prelude: []const u8,
    root_key: []const u8,
    root_source: []const u8,
    loader: ModuleLoader,
    step_limit: u64,
) error{OutOfMemory}!EvaluationResult {
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;

    // Run the harness prelude as a (sloppy) script in the global env to install harness globals.
    if (prelude.len > 0) {
        const pre = Parser.parseMode(arena, prelude, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .syntax_error = "harness prelude parse error" },
        };
        const pc = interp.run(pre, global) catch |e| {
            interp.cleanupGenerators();
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.StepLimitExceeded => .step_limit,
            };
        };
        if (pc == .throw) {
            interp.cleanupGenerators();
            return .{ .thrown = pc.throw };
        }
    }

    var cache: std.StringHashMapUnmanaged(*module_mod.ModuleRecord) = .empty;
    const root = loadGraph(arena, loader, &cache, root_key, root_source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return .{ .syntax_error = "module parse/resolve error" },
    };

    const completion = interp.runModule(root, global) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // §16.2.1.6 a top-level-await module's `runModule` returns its (pending) evaluation PROMISE; the
    // body suspends on `await` and resumes during the Job drain. Capture the promise so we can read
    // its FINAL settled state after the drain (a sync module returns its body completion directly).
    const tla_promise: ?*@import("object.zig").Object = if (root.program.has_top_level_await and completion == .normal and completion.normal == .object and completion.normal.object.promise != null)
        completion.normal.object
    else
        null;
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    // §16.2.1.6 AsyncModuleExecutionFulfilled / …Rejected: surface the awaiting module's settled
    // evaluation result (fulfilled → normal; rejected → thrown) once the drain has resumed its body.
    if (tla_promise) |p| if (p.promise) |pd| switch (pd.state) {
        .fulfilled => return .{ .normal = pd.result },
        .rejected => return .{ .thrown = pd.result },
        .pending => {}, // never settled (e.g. awaited a forever-pending promise) → fall through
    };
    return switch (completion) {
        .normal => |v| .{ .normal = v },
        .empty => .{ .normal = .undefined }, // §6.2.4 empty script value surfaces as undefined
        .throw => |v| .{ .thrown = v },
        .ret => |v| .{ .normal = v },
        .brk, .cont => .{ .normal = .undefined },
    };
}

/// §16.2 evaluate an `[async]`-flagged MODULE test: like `evaluateModule`, but inject the native
/// `$DONE(err)` global (the Test262 async-completion callback) before evaluating the module graph,
/// then DRAIN the Job queue (so top-level-await continuations + Promise reactions complete) and
/// classify via whether/how `$DONE` was called. Used by the runner for module tests with the `async`
/// flag (which call `$DONE()` at the end of their top-level-await body). Deterministic + step-bounded.
pub fn evaluateAsyncModule(
    arena: std.mem.Allocator,
    prelude: []const u8,
    root_key: []const u8,
    root_source: []const u8,
    loader: ModuleLoader,
    step_limit: u64,
) error{OutOfMemory}!AsyncTestResult {
    const interp_mod = @import("interpreter.zig");
    const obj_mod = @import("object.zig");
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    var gen_registry: std.ArrayListUnmanaged(*obj_mod.Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(obj_mod.Job) = .empty;
    const done_sink = arena.create(interp_mod.AsyncDone) catch return error.OutOfMemory;
    done_sink.* = .{};
    const done_fn = obj_mod.Object.createNative(arena, .test_done, "$DONE") catch return error.OutOfMemory;
    if (global.lookup("Function")) |b| if (b.value == .object) {
        if (b.value.object.get("prototype")) |pv| if (pv == .object) {
            done_fn.prototype = pv.object;
        };
    };
    global.declare("$DONE", .{ .object = done_fn }, true, true) catch return error.OutOfMemory;
    if (global.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        gb.value.object.defineData("$DONE", .{ .object = done_fn }, true, false, true) catch return error.OutOfMemory;
    };
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue, .async_done = done_sink };
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;

    if (prelude.len > 0) {
        const pre = Parser.parseMode(arena, prelude, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .syntax_error = "harness prelude parse error" },
        };
        const pc = interp.run(pre, global) catch |e| {
            interp.cleanupGenerators();
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.StepLimitExceeded => .step_limit,
            };
        };
        if (pc == .throw) {
            interp.cleanupGenerators();
            return .{ .sync_throw = pc.throw };
        }
    }

    var cache: std.StringHashMapUnmanaged(*module_mod.ModuleRecord) = .empty;
    const root = loadGraph(arena, loader, &cache, root_key, root_source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return .{ .syntax_error = "module parse/resolve error" },
    };

    const completion = interp.runModule(root, global) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // A module that threw synchronously (before reaching the async machinery / $DONE) failed.
    if (completion == .throw and !done_sink.called) {
        interp.cleanupGenerators();
        return .{ .sync_throw = completion.throw };
    }
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    // A top-level-await module whose evaluation rejected (but never called $DONE) failed synchronously
    // in spirit — surface the rejection reason so the runner can report it.
    if (!done_sink.called) {
        if (root.program.has_top_level_await and completion == .normal and completion.normal == .object) {
            if (completion.normal.object.promise) |pd| if (pd.state == .rejected) return .{ .sync_throw = pd.result };
        }
        return .never_done;
    }
    if (done_sink.failed) return .{ .async_fail = done_sink.message };
    return .async_pass;
}

/// Like `evaluate`, but with an explicit interpreter step cap (the watchdog, research D8).
/// The Test262 harness uses this to bound runaway tests deterministically.
pub fn evaluateWithLimit(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64) error{OutOfMemory}!EvaluationResult {
    return evaluateWithLimitL(arena, source, mode, step_limit, null, "");
}

/// §13.3.10 like `evaluateWithLimit`, but with the optional minimal harness module loader (+ the
/// script's referrer key) threaded in so a script-context dynamic `import()` can resolve + load a
/// fixture module. `loader == null` is the plain `evaluate` behavior (import() rejects with a
/// TypeError). The per-run module cache lives on `arena` for the realm's lifetime.
pub fn evaluateWithLimitL(arena: std.mem.Allocator, source: []const u8, mode: RunMode, step_limit: u64, loader: ?ModuleLoader, referrer_key: []const u8) error{OutOfMemory}!EvaluationResult {
    // §11.2.2: in strict RunMode the whole Script starts in strict context (the Test262 runner runs
    // each test in both modes and expects the engine to honor this). An explicit `"use strict"`
    // directive prologue is detected independently inside the parser.
    const program = Parser.parseMode(arena, source, mode == .strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = syntaxMsg(arena, source, e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    // §27.5 generator registry — the main interpreter tracks every generator created in this realm so
    // any never-fully-consumed generator's parked body thread can be unwound + joined at end-of-run.
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    // §9.5 the realm Job (microtask) queue — drained once the synchronous script completes (Promise
    // reactions / async-function continuations run here). Empty for a script with no promises (no-op).
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    var mcache: std.StringHashMapUnmanaged(*module_mod.ModuleRecord) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = step_limit, .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    if (loader) |l| {
        interp.module_loader = l;
        interp.module_cache = &mcache;
        interp.host_referrer_key = referrer_key;
    }
    // §9.4.2 GetThisBinding: the global environment's `this` is the global object (both modes).
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;
    const completion = interp.run(program, global) catch |e| {
        interp.cleanupGenerators(); // join/abandon any parked generator threads before unwinding
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // §9.5 RunJobs: drain the microtask queue (Promise reactions + await resumptions) now the stack is
    // empty. Step-bounded — a runaway microtask loop terminates as `step_limit`, never hangs. A script
    // with no promises has an empty queue (no-op; non-async tests classify exactly as before).
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators(); // join/abandon any parked generator/async threads (no lingering OS thread)
    return switch (completion) {
        .normal => |v| .{ .normal = v },
        .empty => .{ .normal = .undefined }, // §6.2.4 empty script value surfaces as undefined
        .throw => |v| .{ .thrown = v },
        .ret => |v| .{ .normal = v }, // stray top-level return → its value
        // TODO(Cycle B/D): top-level return/break/continue should be parse-phase SyntaxErrors.
        .brk, .cont => .{ .normal = .undefined },
    };
}

const host_timers = @import("host_timers.zig");
const host_setup = @import("host_setup.zig");

/// HOST (Node axis, spec 100): re-exported so the CLI (`main`) builds the argv/env/cwd context.
pub const HostCtx = host_setup.HostCtx;

/// HOST run (Node axis, spec 098/100): like `evaluate`, but installs the host globals (`process`,
/// `global`, timers, `console`) from `ctx`, then — after the top-level script + initial nextTick +
/// microtask drain — runs the **event loop** (`runEventLoop`) until the timer queue empties. Used by
/// the `ljs run` CLI so timers + `console.log` + `process` work. NOT used by Test262 (that path stays
/// microtask-only, never installs host globals, and never sleeps).
pub fn runHost(arena: std.mem.Allocator, source: []const u8, mode: RunMode, ctx: HostCtx, out: *std.Io.Writer, err: *std.Io.Writer) error{OutOfMemory}!EvaluationResult {
    const program = Parser.parseMode(arena, source, mode == .strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = syntaxMsg(arena, source, e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    // HOST CLI path: real programs run UNBOUNDED (like Node). The step limit is a Test262-determinism
    // guard (no hangs in the conformance harness); a `ljs run` of a real program must not hit it.
    var interp = Interpreter{ .arena = arena, .step_limit = std.math.maxInt(u64), .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    interp.host_out = out;
    interp.host_err = err;
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;
    host_setup.installHostGlobals(&interp, ctx) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimitExceeded => return .step_limit,
    };
    const completion = interp.run(program, global) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // A synchronous throw aborts the host run before the loop (like Node printing an uncaught error and
    // exiting) — surface it; don't run timers scheduled before the throw.
    if (completion == .throw) {
        interp.cleanupGenerators();
        return .{ .thrown = completion.throw };
    }
    // §process.nextTick: drain ticks scheduled by the top-level script BEFORE the first microtask
    // checkpoint, so a `process.nextTick` runs ahead of a same-turn `Promise.then` (Node ordering). The
    // event loop re-drains at the top of each turn; this seeds the pre-loop checkpoint.
    host_setup.drainNextTicks(&interp) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // Drive the macrotask/microtask event loop to completion (timers fire here).
    host_timers.runEventLoop(&interp) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    // §process: fire the `'exit'` event with the resolved exit code (from `process.exitCode`,
    // default 0) at the natural end of the run. A `process.exit()` earlier already fired + terminated;
    // this only runs on the fall-off-the-end path. The handler runs synchronously.
    host_setup.emitExit(&interp, host_setup.resolveExitCode(&interp)) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    return switch (completion) {
        .normal => |v| .{ .normal = v },
        .empty => .{ .normal = .undefined },
        .ret => |v| .{ .normal = v },
        .throw => |v| .{ .thrown = v },
        .brk, .cont => .{ .normal = .undefined },
    };
}

/// HOST `ljs run <file.mjs>` (Node axis, spec 110): run an ES-module ENTRY. Like `runHost` but the
/// program is parsed + linked + evaluated as a MODULE graph (top-level `import`/`export` work; relative
/// imports resolve against the entry's dir; CJS deps are bridged). Host globals + event loop + exit are
/// identical to `runHost`. `ctx.script_path` is the module's resolved key.
pub fn runHostModule(arena: std.mem.Allocator, source: []const u8, ctx: HostCtx, out: *std.Io.Writer, err: *std.Io.Writer) error{OutOfMemory}!EvaluationResult {
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    var interp = Interpreter{ .arena = arena, .step_limit = std.math.maxInt(u64), .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    interp.host_out = out;
    interp.host_err = err;
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;
    host_setup.installHostGlobals(&interp, ctx) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimitExceeded => return .step_limit,
    };
    const completion = @import("host_require.zig").runEsmEntry(&interp, ctx.script_path, source) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    if (completion == .throw) {
        interp.cleanupGenerators();
        return .{ .thrown = completion.throw };
    }
    host_setup.drainNextTicks(&interp) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimitExceeded => {
            interp.cleanupGenerators();
            return .step_limit;
        },
    };
    host_timers.runEventLoop(&interp) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    host_setup.emitExit(&interp, host_setup.resolveExitCode(&interp)) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    return .{ .normal = .undefined };
}

/// HOST `ljs eval` (Node axis, spec 100): like `evaluate`, but installs the host globals (so
/// `console.log` / `process` work) and threads the run's stdout/stderr writers — WITHOUT running the
/// event loop (a one-shot REPL-style evaluation; a `setTimeout`/`process.nextTick` scheduled here
/// simply never fires, which is acceptable). The microtask Job queue is still drained (Promise
/// reactions run). Returns the script's completion value (the CLI echoes it REPL-style).
pub fn evalHost(arena: std.mem.Allocator, source: []const u8, mode: RunMode, ctx: HostCtx, out: *std.Io.Writer, err: *std.Io.Writer) error{OutOfMemory}!EvaluationResult {
    const program = Parser.parseMode(arena, source, mode == .strict) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .syntax_error = syntaxMsg(arena, source, e) },
    };
    const global = Environment.create(arena, null) catch return error.OutOfMemory;
    builtins.setup(arena, global) catch return error.OutOfMemory;
    var gen_registry: std.ArrayListUnmanaged(*@import("object.zig").Generator) = .empty;
    var job_queue: std.ArrayListUnmanaged(@import("object.zig").Job) = .empty;
    // HOST CLI path: real programs run UNBOUNDED (like Node). The step limit is a Test262-determinism
    // guard (no hangs in the conformance harness); a `ljs run` of a real program must not hit it.
    var interp = Interpreter{ .arena = arena, .step_limit = std.math.maxInt(u64), .globals = global, .gen_registry = &gen_registry, .job_queue = &job_queue };
    interp.host_out = out;
    interp.host_err = err;
    interp.this_val = if (global.lookup("%GlobalThis%")) |b| b.value else .undefined;
    host_setup.installHostGlobals(&interp, ctx) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimitExceeded => return .step_limit,
    };
    const completion = interp.run(program, global) catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.drainJobs() catch |e| {
        interp.cleanupGenerators();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StepLimitExceeded => .step_limit,
        };
    };
    interp.cleanupGenerators();
    return switch (completion) {
        .normal => |v| .{ .normal = v },
        .empty => .{ .normal = .undefined },
        .ret => |v| .{ .normal = v },
        .throw => |v| .{ .thrown = v },
        .brk, .cont => .{ .normal = .undefined },
    };
}
