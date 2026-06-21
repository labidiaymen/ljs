//! HOST runtime (Node axis, spec 106 Unit A — NOT ECMA-262): a minimal `node:test` runner.
//! Requireable as `require('node:test')` / `require('test')` (the `node:` prefix is stripped by
//! `host_require.coreName`, so registering `"test"` covers both). Host-only — never on the Test262
//! engine surface (host core modules are not requireable there).
//!
//! The default export is the CALLABLE `test(name?, opts?, fn)` that ALSO carries the named runner
//! functions as own properties: `test`, `describe`, `it`, `before`, `after`, `beforeEach`,
//! `afterEach`, `mock`, plus the `test.skip` / `test.todo` / `test.only` (and `it.*`) variants.
//!
//! Mechanics: every runner native is a `.nodetest_method` whose `native_name` selects the operation.
//! A small bit of per-run state (the failure/total counters and the "exit handler registered" flag)
//! lives as hidden own props on the cached module-exports object (`%failed%` / `%total%` /
//! `%hookExit%`). The first `test()` / `describe()` / `it()` call registers a `process.on('exit')`
//! handler (itself a `.nodetest_method` named "%exit%") that, at the natural end of the run, calls
//! `process.exit(1)` when any test failed — so the exit-code harness classifies the file as failed.
//!
//! A top-level `test`/`it` whose body THROWS (e.g. an assert failure) is recorded as a FAILURE and
//! the run continues. A body that returns a thenable is awaited via the event loop: a rejection is
//! recorded as a failure, and because the loop drains all pending jobs before the `'exit'` event
//! fires, the handler observes the final failure count. `describe` runs its body synchronously (it
//! registers the nested `it`s). The `t` context exposes `t.test` (subtests), `t.assert` (the `assert`
//! module), `t.diagnostic` (a no-op), `t.mock` (a minimal mock surface), and `t.skip`/`t.todo`.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const ops = @import("abstract_ops.zig");

const eql = std.mem.eql;

const FAILED_KEY = "%failed%";
const TOTAL_KEY = "%total%";
const HOOK_KEY = "%hookExit%";

// ── build the module ─────────────────────────────────────────────────────────────

/// Build the `node:test` module exports: the callable `test` native carrying the named runner
/// functions + the `skip`/`todo`/`only` variants. The same object is the cached exports and the
/// per-run state holder (hidden `%failed%` / `%total%` / `%hookExit%`).
pub fn build(self: *Interpreter) EvalError!*Object {
    // The default export IS the callable `test(name?, opts?, fn)` (a `.nodetest_method` named "test")
    // that also carries the runner functions as own props.
    const root = try makeMethod(self, "test");

    // The per-run counters / hook flag live as hidden own props on the exports object.
    try root.defineData(FAILED_KEY, .{ .number = 0 }, true, false, false);
    try root.defineData(TOTAL_KEY, .{ .number = 0 }, true, false, false);
    try root.defineData(HOOK_KEY, .{ .boolean = false }, true, false, false);

    // Named runner functions.
    try attach(self, root, "test", "test");
    try attach(self, root, "describe", "describe");
    try attach(self, root, "suite", "describe"); // `suite` is an alias of `describe`
    try attach(self, root, "it", "it");
    try attach(self, root, "before", "hook");
    try attach(self, root, "after", "hook");
    try attach(self, root, "beforeEach", "hook");
    try attach(self, root, "afterEach", "hook");
    try attach(self, root, "mock", "mock");

    // `test.skip` / `test.todo` / `test.only` (and the same on `describe`/`it`/`suite`).
    try attachVariants(self, root);
    if (root.get("describe")) |d| if (d == .object) try attachVariants(self, d.object);
    if (root.get("it")) |i| if (i == .object) try attachVariants(self, i.object);
    if (root.get("suite")) |s| if (s == .object) try attachVariants(self, s.object);

    return root;
}

/// Attach the `.skip` / `.todo` / `.only` sub-variants onto a runner function.
fn attachVariants(self: *Interpreter, target: *Object) EvalError!void {
    try attach(self, target, "skip", "skip");
    try attach(self, target, "todo", "todo");
    try attach(self, target, "only", "test"); // `only` runs like a normal test here
}

/// Create a bare `.nodetest_method` native function object named `name`.
fn makeMethod(self: *Interpreter, name: []const u8) EvalError!*Object {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .nodetest_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    return fn_obj;
}

/// Define `key` on `target` as a `.nodetest_method` native whose dispatch name is `impl`.
fn attach(self: *Interpreter, target: *Object, key: []const u8, impl: []const u8) EvalError!void {
    const fn_obj = try makeMethod(self, impl);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

// ── module-state access (the cached exports object holds the counters) ────────────

/// The cached `node:test` exports object (the state holder), or null if not yet built.
fn stateObj(self: *Interpreter) ?*Object {
    if (self.core_module_cache.get("test")) |exports| {
        if (exports == .object) return exports.object;
    }
    return null;
}

/// Print a line of TAP output to the host stdout (best-effort; no-op off the host path).
fn tap(self: *Interpreter, text: []const u8) void {
    const w = self.host_out orelse return;
    w.writeAll(text) catch return;
    w.writeAll("\n") catch return;
    w.flush() catch return;
}

/// Report a finished test as a TAP line: `ok N - name` / `not ok N - name` (N = the running total).
fn reportTest(self: *Interpreter, name: []const u8, ok: bool) void {
    const obj = stateObj(self) orelse return;
    const n: u64 = @intFromFloat(@max(readCount(obj, TOTAL_KEY), 0));
    const label = if (name.len > 0) name else "(anonymous)";
    const line = std.fmt.allocPrint(self.arena, "{s} {d} - {s}", .{ if (ok) "ok" else "not ok", n, label }) catch return;
    tap(self, line);
}

fn readCount(obj: *Object, key: []const u8) f64 {
    if (obj.get(key)) |v| if (v == .number) return v.number;
    return 0;
}

fn bumpFailed(self: *Interpreter) EvalError!void {
    const obj = stateObj(self) orelse return;
    try obj.defineData(FAILED_KEY, .{ .number = readCount(obj, FAILED_KEY) + 1 }, true, false, false);
}

fn bumpTotal(self: *Interpreter) EvalError!void {
    const obj = stateObj(self) orelse return;
    try obj.defineData(TOTAL_KEY, .{ .number = readCount(obj, TOTAL_KEY) + 1 }, true, false, false);
}

// ── dispatch ─────────────────────────────────────────────────────────────────────

/// Dispatch a `.nodetest_method` native by `func.native_name`.
pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    _ = this_val;
    const name = func.native_name;

    // The process-'exit' reaction native: terminate non-zero if any test failed.
    if (eql(u8, name, "%exit%")) return exitHandler(self);
    // A test-body promise reject reaction: record a failure.
    if (eql(u8, name, "%fail_reaction%")) {
        try bumpFailed(self);
        return .{ .normal = .undefined };
    }

    if (eql(u8, name, "test") or eql(u8, name, "it")) return runTest(self, args, .normal);
    if (eql(u8, name, "skip")) return runTest(self, args, .skip);
    if (eql(u8, name, "todo")) return runTest(self, args, .todo);
    if (eql(u8, name, "describe")) return runDescribe(self, args);
    if (eql(u8, name, "hook")) return runHook(self, args);
    if (eql(u8, name, "mock")) return .{ .normal = .{ .object = try makeMock(self) } };
    if (eql(u8, name, "diagnostic")) return .{ .normal = .undefined };

    return .{ .normal = .undefined };
}

const Mode = enum { normal, skip, todo };

// ── argument parsing: (name?, opts?, fn?) ─────────────────────────────────────────

const ParsedArgs = struct {
    name: []const u8 = "<anonymous>",
    fn_obj: ?*Object = null,
    skip: bool = false,
    todo: bool = false,
};

/// Parse the flexible `(name?, opts?, fn)` argument list shared by `test`/`it`/`describe`. The name is
/// an optional leading string; an options object (`{ skip, todo, only, ... }`) may appear before the
/// function; the function is the last callable.
fn parseArgs(args: []const Value) ParsedArgs {
    var out: ParsedArgs = .{};
    var idx: usize = 0;

    if (idx < args.len and args[idx] == .string) {
        out.name = args[idx].string;
        idx += 1;
    } else if (idx < args.len and args[idx] == .object and args[idx].object.kind == .function) {
        // A named function as the first arg → use its `name` as the test name.
        if (args[idx].object.get("name")) |nm| if (nm == .string and nm.string.len > 0) {
            out.name = nm.string;
        };
    }

    // Optional options object (must not be the function itself).
    if (idx < args.len and args[idx] == .object and args[idx].object.kind != .function) {
        const opts = args[idx].object;
        if (opts.get("skip")) |v| out.skip = ops.toBoolean(v);
        if (opts.get("todo")) |v| out.todo = ops.toBoolean(v);
        idx += 1;
    }

    // The function is the next callable argument (if any).
    while (idx < args.len) : (idx += 1) {
        if (args[idx] == .object and args[idx].object.kind == .function) {
            out.fn_obj = args[idx].object;
            break;
        }
    }
    return out;
}

// ── test / it ─────────────────────────────────────────────────────────────────────

/// `test(name?, opts?, fn)` / `it(...)` — register-and-run one test. A skip/todo test is recorded as a
/// pass without running. A sync throw is recorded as a failure. A returned thenable is awaited via the
/// event loop (its rejection becomes a failure).
fn runTest(self: *Interpreter, args: []const Value, mode: Mode) EvalError!Completion {
    try ensureExitHook(self);
    try bumpTotal(self);

    const p = parseArgs(args);
    if (mode == .skip or mode == .todo or p.skip or p.todo) {
        // Skipped / todo → counts as a (non-failing) result; the body is not run.
        return .{ .normal = .undefined };
    }
    const fn_obj = p.fn_obj orelse return .{ .normal = .undefined };

    // Build the `t` context and call the body with it.
    const t = try makeContext(self, p.name);
    const c = try self.callFunction(fn_obj, &.{.{ .object = t }}, .undefined);
    if (c == .throw) {
        try bumpFailed(self);
        reportTest(self, p.name, false);
        return .{ .normal = .undefined }; // SWALLOW: a failing test does not abort the file
    }
    // An async body: await its settlement so a rejection is recorded as a failure (the per-test TAP
    // line for async tests is omitted — only the end-of-run summary reflects them).
    if (c.normal == .object and c.normal.object.promise != null) {
        try awaitResult(self, c.normal.object);
    } else {
        reportTest(self, p.name, true);
    }
    return .{ .normal = .undefined };
}

/// Attach reactions to a test-body promise: a rejection (or a thenable that rejects) bumps the failure
/// counter. The reaction natives run during the event-loop drain, before the `'exit'` event fires.
fn awaitResult(self: *Interpreter, promise: *Object) EvalError!void {
    const pd = promise.promise.?;
    // A reject reaction native flagged so dispatch records a failure.
    const on_reject = try makeMethod(self, "%fail_reaction%");
    switch (pd.state) {
        .rejected => _ = try self.callFunction(on_reject, &.{pd.result}, .undefined),
        .fulfilled => {}, // fulfilled body → pass
        .pending => {
            pd.reject_reactions.append(self.arena, .{ .kind = .reject, .handler = on_reject, .capability = null }) catch return error.OutOfMemory;
            // A null fulfill handler is fine — a fulfilled body is a pass and needs no reaction.
            pd.fulfill_reactions.append(self.arena, .{ .kind = .fulfill, .handler = null, .capability = null }) catch return error.OutOfMemory;
        },
    }
}

// ── describe / suite ──────────────────────────────────────────────────────────────

/// `describe(name?, opts?, fn)` — run the suite body synchronously (it registers the nested `it`s). A
/// skip/todo suite is not run. A throw in the body is recorded as a failure.
fn runDescribe(self: *Interpreter, args: []const Value) EvalError!Completion {
    try ensureExitHook(self);
    const p = parseArgs(args);
    if (p.skip or p.todo) return .{ .normal = .undefined };
    const fn_obj = p.fn_obj orelse return .{ .normal = .undefined };

    const t = try makeContext(self, p.name);
    const c = try self.callFunction(fn_obj, &.{.{ .object = t }}, .undefined);
    if (c == .throw) {
        try bumpTotal(self);
        try bumpFailed(self);
        return .{ .normal = .undefined };
    }
    if (c.normal == .object and c.normal.object.promise != null) {
        try bumpTotal(self);
        try awaitResult(self, c.normal.object);
    }
    return .{ .normal = .undefined };
}

// ── before / after / beforeEach / afterEach hooks ─────────────────────────────────

/// `before`/`after`/`beforeEach`/`afterEach(fn)` — run the hook function immediately (a minimal model
/// that is sufficient for the file-level setup the tests use). A throw is recorded as a failure.
fn runHook(self: *Interpreter, args: []const Value) EvalError!Completion {
    const fn_obj: ?*Object = blk: {
        for (args) |a| if (a == .object and a.object.kind == .function) break :blk a.object;
        break :blk null;
    };
    const f = fn_obj orelse return .{ .normal = .undefined };
    const c = try self.callFunction(f, &.{}, .undefined);
    if (c == .throw) {
        try ensureExitHook(self);
        try bumpTotal(self);
        try bumpFailed(self);
        return .{ .normal = .undefined };
    }
    if (c.normal == .object and c.normal.object.promise != null) try awaitResult(self, c.normal.object);
    return .{ .normal = .undefined };
}

// ── the `t` test context ──────────────────────────────────────────────────────────

/// Build the `t` context object passed to a test body: `t.test`/`t.it` (subtests, same machinery),
/// `t.assert` (the `assert` module), `t.diagnostic` (no-op), `t.mock`, `t.skip`/`t.todo` (no-ops),
/// `t.name`.
fn makeContext(self: *Interpreter, name: []const u8) EvalError!*Object {
    const arena = self.arena;
    const t = try Object.create(arena, self.objectProto());
    try t.defineData("name", .{ .string = name }, true, true, true);

    // t.test / t.it — subtests run with the same machinery as a top-level test.
    try attach(self, t, "test", "test");
    try attach(self, t, "it", "test");
    try attach(self, t, "describe", "describe");

    // t.diagnostic(msg) / t.skip() / t.todo() — accepted no-ops.
    try attach(self, t, "diagnostic", "diagnostic");
    try attach(self, t, "skip", "diagnostic");
    try attach(self, t, "todo", "diagnostic");

    // t.assert — the `assert` module (callable + methods). Best-effort; absent on failure.
    const assert_c = try @import("host_require.zig").loadCoreModulePub(self, "assert");
    if (!assert_c.isAbrupt() and assert_c.normal == .object) {
        try t.defineData("assert", assert_c.normal, true, true, true);
    }

    // t.mock — a minimal mock surface.
    const mk = try makeMock(self);
    try t.defineData("mock", .{ .object = mk }, true, true, true);
    return t;
}

// ── minimal mock surface ──────────────────────────────────────────────────────────

/// A minimal `mock` object: `fn`/`method`/`getter`/`setter`/`reset`/`restoreAll`/`timers` natives,
/// each a no-op returning undefined. Enough to not crash the common patterns.
fn makeMock(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const m = try Object.create(arena, self.objectProto());
    for ([_][]const u8{ "fn", "method", "getter", "setter", "reset", "restoreAll", "timers" }) |k| {
        const fn_obj = try makeMethod(self, "diagnostic"); // dispatch as a no-op returning undefined
        try m.defineData(k, .{ .object = fn_obj }, true, true, true);
    }
    return m;
}

// ── process.on('exit') hook ───────────────────────────────────────────────────────

/// Register the `process.on('exit')` handler the first time any runner is called (idempotent via the
/// hidden `%hookExit%` flag on the state object). The handler terminates the process non-zero when any
/// test failed.
fn ensureExitHook(self: *Interpreter) EvalError!void {
    const obj = stateObj(self) orelse return;
    if (obj.get(HOOK_KEY)) |v| if (v == .boolean and v.boolean) return; // already registered
    try obj.defineData(HOOK_KEY, .{ .boolean = true }, true, false, false);

    const process = self.process_obj orelse return;
    const on_v = try self.getProperty(.{ .object = process }, "on");
    if (on_v.isAbrupt() or on_v.normal != .object) return;
    const handler = try makeMethod(self, "%exit%");
    _ = try self.callFunction(on_v.normal.object, &.{ .{ .string = "exit" }, .{ .object = handler } }, .{ .object = process });
}

/// The `process.on('exit')` reaction: if any test failed, force a non-zero exit so the harness
/// classifies the file as failed. Calling `process.exit(1)` terminates the process (the `'exit'`
/// event has already fired, so it is not re-emitted).
fn exitHandler(self: *Interpreter) EvalError!Completion {
    const obj = stateObj(self) orelse return .{ .normal = .undefined };
    // End-of-run TAP summary: the plan line + pass/fail tallies.
    const total: u64 = @intFromFloat(@max(readCount(obj, TOTAL_KEY), 0));
    const failed: u64 = @intFromFloat(@max(readCount(obj, FAILED_KEY), 0));
    if (total > 0) {
        const summary = std.fmt.allocPrint(self.arena, "1..{d}\n# tests {d}\n# pass {d}\n# fail {d}", .{ total, total, total - failed, failed }) catch return .{ .normal = .undefined };
        tap(self, summary);
    }
    if (failed == 0) return .{ .normal = .undefined };

    // Drive `process.exit(1)`.
    const process = self.process_obj orelse return .{ .normal = .undefined };
    const exit_v = try self.getProperty(.{ .object = process }, "exit");
    if (exit_v.isAbrupt() or exit_v.normal != .object) return .{ .normal = .undefined };
    return self.callFunction(exit_v.normal.object, &.{.{ .number = 1 }}, .{ .object = process });
}
