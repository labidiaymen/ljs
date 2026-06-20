//! HOST runtime setup (Node axis, spec 100 — NOT ECMA-262): install the host-only globals on a realm
//! that the CLI (`ljs run` / `ljs eval`) uses — the `process` object, the `global` alias for
//! globalThis, the timer globals (`setTimeout`/…/`queueMicrotask`/`setImmediate`), and `console`.
//!
//! These are deliberately NOT in `builtins.setup` (the shared Test262 path): `process` needs
//! argv/env/cwd from the CLI entry, and a Test262 realm must be pure ECMAScript (no host globals at
//! all). `runHost` / `ljs eval` call `installHostGlobals` AFTER `builtins.setup`; the conformance
//! engine surface never does, so moving the slice-1/2 timer + console globals here keeps the 0-Test262
//! -regression guarantee (the suite never referenced them).
const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;

/// The host context passed from the CLI entry (`main`) into `installHostGlobals`: the data needed to
/// build `process` that only the host process can see. `argv` is `[execPath, scriptPath, ...extra]`;
/// `env_pairs` is a snapshot of the OS environment as `key→value` pairs; `cwd` is the working
/// directory; `pid` the OS process id (0 if unavailable).
pub const HostCtx = struct {
    argv: []const []const u8,
    env_pairs: []const [2][]const u8,
    cwd: []const u8,
    pid: i64 = 0,
    /// HOST (spec 102): the entry script's ABSOLUTE path + directory, so `require`/`__filename`/
    /// `__dirname` can be injected for the top-level script (`ljs run <file>`). Empty for `ljs eval`
    /// (no script file) → no `require` is injected (a `require` call would then be a ReferenceError).
    script_path: []const u8 = "",
    script_dir: []const u8 = "",
};

/// `@import("builtin").os.tag` → the Node `process.platform` string (best-effort coverage of the
/// common targets; falls back to the Zig tag name).
fn platformString() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win32",
        .linux => "linux",
        .macos => "darwin",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        else => @tagName(builtin.os.tag),
    };
}

/// `@import("builtin").cpu.arch` → the Node `process.arch` string.
fn archString() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "ia32",
        .aarch64 => "arm64",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}

/// Build + declare the host globals on `self.globals`: `process`, `global`, the timer globals, and
/// `console`. Called by `runHost` / `ljs eval` after `builtins.setup`. The native function objects
/// proto-link to %Function.prototype% so `process.exit.call(...)` etc. resolve. The `ctx` data is
/// captured by value into the `process` properties; the native methods read it off the interpreter
/// (cwd) or off the OS at call time (exit).
pub fn installHostGlobals(self: *Interpreter, ctx: HostCtx) EvalError!void {
    const arena = self.arena;
    const env = self.globals orelse return;
    const function_proto = self.functionProto();
    const object_proto = self.objectProto();
    const array_proto = self.arrayProto();

    // Stash the cwd so `process.cwd()` can return it without re-querying the OS (the value `main`
    // resolved at startup, matching Node's "cwd at process launch unless chdir'd" — we have no chdir).
    self.host_cwd = ctx.cwd;

    // ── timer globals (moved here from builtins.setup, spec 100) ──────────────────────────────────
    const timer_fns = [_][]const u8{ "setTimeout", "setInterval", "clearTimeout", "clearInterval", "queueMicrotask", "setImmediate", "clearImmediate" };
    for (timer_fns) |tf| {
        const fn_obj = try Object.createNative(arena, .timer_fn, tf);
        fn_obj.prototype = function_proto;
        try fn_obj.defineData("name", .{ .string = tf }, false, false, true);
        try env.declare(tf, .{ .object = fn_obj }, true, true);
    }

    // ── console (moved here from builtins.setup, spec 100) ────────────────────────────────────────
    {
        const console_obj = try Object.create(arena, object_proto);
        const log_fn = try Object.createNative(arena, .console_log, "log");
        log_fn.prototype = function_proto;
        try log_fn.defineData("name", .{ .string = "log" }, false, false, true);
        try console_obj.defineData("log", .{ .object = log_fn }, true, false, true);
        for ([_][]const u8{ "info", "debug", "warn", "error" }) |alias|
            try console_obj.defineData(alias, .{ .object = log_fn }, true, false, true);
        try env.declare("console", .{ .object = console_obj }, true, true);
    }

    // ── process ───────────────────────────────────────────────────────────────────────────────────
    const process = try Object.create(arena, object_proto);

    // process.argv — [execPath, scriptPath, ...extra].
    {
        const argv_arr = try Object.createArray(arena, array_proto);
        for (ctx.argv, 0..) |a, i| try argv_arr.arraySet(arena, i, .{ .string = a });
        try process.defineData("argv", .{ .object = argv_arr }, true, true, true);
    }
    const argv0: []const u8 = if (ctx.argv.len > 0) ctx.argv[0] else "ljs";
    try process.defineData("argv0", .{ .string = argv0 }, true, true, true);
    try process.defineData("execPath", .{ .string = argv0 }, true, true, true);

    // process.env — a plain object snapshot of the OS environment.
    {
        const env_obj = try Object.create(arena, object_proto);
        for (ctx.env_pairs) |pair|
            try env_obj.defineData(pair[0], .{ .string = pair[1] }, true, true, true);
        try process.defineData("env", .{ .object = env_obj }, true, true, true);
    }

    try process.defineData("platform", .{ .string = platformString() }, true, true, true);
    try process.defineData("arch", .{ .string = archString() }, true, true, true);
    try process.defineData("version", .{ .string = "v22.0.0" }, true, true, true);
    try process.defineData("pid", .{ .number = @floatFromInt(ctx.pid) }, true, true, true);

    // process.versions — { node, v8, ljs }.
    {
        const versions = try Object.create(arena, object_proto);
        try versions.defineData("node", .{ .string = "22.0.0" }, true, true, true);
        try versions.defineData("v8", .{ .string = "12.4.0" }, true, true, true);
        try versions.defineData("ljs", .{ .string = "0.1.0" }, true, true, true);
        try process.defineData("versions", .{ .object = versions }, true, true, true);
    }

    // process.cwd() / process.exit([code]) / process.nextTick(cb, ...args).
    try defineHostMethod(self, process, "cwd", "cwd", function_proto);
    try defineHostMethod(self, process, "exit", "exit", function_proto);
    try defineHostMethod(self, process, "nextTick", "nextTick", function_proto);

    // process.stdout / process.stderr — objects with a `write` method routing to the run's writers.
    {
        const stdout = try Object.create(arena, object_proto);
        try defineHostMethod(self, stdout, "write", "stdoutWrite", function_proto);
        try process.defineData("stdout", .{ .object = stdout }, true, true, true);
        const stderr = try Object.create(arena, object_proto);
        try defineHostMethod(self, stderr, "write", "stderrWrite", function_proto);
        try process.defineData("stderr", .{ .object = stderr }, true, true, true);
    }

    try env.declare("process", .{ .object = process }, true, true);

    // ── Buffer (spec 101) ───────────────────────────────────────────────────────────────────────────
    try @import("host_buffer.zig").installBuffer(self, function_proto);

    // ── CommonJS require / module / exports / __filename / __dirname (spec 102) ──────────────────────
    // Only for `ljs run <file>` (a known script path); `ljs eval` leaves these absent.
    if (ctx.script_path.len > 0)
        try @import("host_require.zig").installEntryRequire(self, ctx.script_path, ctx.script_dir);

    // process is also an own property of the global object (so `globalThis.process` works).
    if (env.lookup("%GlobalThis%")) |gb| if (gb.value == .object) {
        try gb.value.object.defineData("process", .{ .object = process }, true, false, true);
        // global = globalThis (Node alias).
        try env.declare("global", gb.value, true, true);
        try gb.value.object.defineData("global", gb.value, true, false, true);
        // Mirror the host globals onto the reified global object too (so globalThis.console etc. work).
        for ([_][]const u8{ "console", "setTimeout", "setInterval", "clearTimeout", "clearInterval", "queueMicrotask", "setImmediate", "clearImmediate" }) |name| {
            if (env.lookup(name)) |b| try gb.value.object.defineData(name, b.value, true, false, true);
        }
    };
}

/// Define a `process_method` native (the `native_name` selects the impl) as a non-enumerable method on
/// `target` (so `Object.keys(process)` doesn't surface it but it is callable). `key` is the property
/// name; `impl` is the dispatch selector (`native_name`).
fn defineHostMethod(self: *Interpreter, target: *Object, key: []const u8, impl: []const u8, function_proto: ?*Object) EvalError!void {
    const fn_obj = try Object.createNative(self.arena, .process_method, impl);
    fn_obj.prototype = function_proto;
    _ = fn_obj.properties.orderedRemove("prototype"); // a method has no own `prototype`
    try fn_obj.defineData("name", .{ .string = key }, false, false, true);
    try target.defineData(key, .{ .object = fn_obj }, true, false, true);
}

/// Dispatch a `process_method` native by `name`. Called from `interp_native.callNative`.
pub fn processMethod(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "cwd")) {
        return .{ .normal = .{ .string = self.host_cwd } };
    }
    if (std.mem.eql(u8, name, "exit")) {
        // §process.exit([code]): ToInt32-ish — Node coerces to an integer, NaN/undefined → 0. Flush the
        // host writers (so buffered console output reaches the terminal) before terminating the process.
        var code: u8 = 0;
        if (args.len > 0 and args[0] != .undefined) {
            const nd = try self.toNumberV(args[0]);
            if (nd.isAbrupt()) return nd;
            const n = nd.normal.number;
            if (!std.math.isNan(n)) {
                const t = std.math.trunc(n);
                // Node truncates to a uint8 (mod 256); clamp before the cast (a huge `t` would overflow
                // i64) so `process.exit(256) === 0`.
                const wrapped: i64 = @intFromFloat(@max(@min(t, 2_000_000_000), -2_000_000_000));
                code = @intCast(@mod(wrapped, 256));
            }
        }
        // Best-effort flush before terminating; a broken pipe must not block exit.
        if (self.host_out) |w| w.flush() catch |e| std.log.debug("process.exit: stdout flush failed: {s}", .{@errorName(e)});
        if (self.host_err) |w| w.flush() catch |e| std.log.debug("process.exit: stderr flush failed: {s}", .{@errorName(e)});
        std.process.exit(code);
    }
    if (std.mem.eql(u8, name, "nextTick")) {
        const cb = if (args.len > 0) args[0] else .undefined;
        if (cb != .object or cb.object.kind != .function)
            return self.throwError("TypeError", "process.nextTick requires a callback function");
        const extra: []const Value = if (args.len > 1) try self.arena.dupe(Value, args[1..]) else &.{};
        self.next_tick_queue.append(self.arena, .{ .callback = cb.object, .args = extra }) catch return error.OutOfMemory;
        return .{ .normal = .undefined };
    }
    if (std.mem.eql(u8, name, "stdoutWrite")) return writeStream(self, self.host_out, args);
    if (std.mem.eql(u8, name, "stderrWrite")) return writeStream(self, self.host_err, args);
    return .{ .normal = .undefined };
}

/// `process.stdout.write(s)` / `process.stderr.write(s)`: ToString(arg[0]) → the writer, return `true`.
/// A non-string is coerced (Node writes the ToString); a write/flush failure ends the write but does
/// not throw (a closed pipe must not abort the script).
fn writeStream(self: *Interpreter, writer: ?*std.Io.Writer, args: []const Value) EvalError!Completion {
    const arg: Value = if (args.len > 0) args[0] else .undefined;
    const sc = try self.toStringValuePub(arg);
    if (sc.isAbrupt()) return sc;
    if (writer) |w| {
        w.writeAll(sc.normal.string) catch return .{ .normal = .{ .boolean = true } };
        w.flush() catch return .{ .normal = .{ .boolean = true } };
    }
    return .{ .normal = .{ .boolean = true } };
}

/// HOST (spec 100): drain the entire nextTick queue (running each callback to completion, including
/// ticks they enqueue) — the FIFO pre-microtask checkpoint. A callback that throws is reported via
/// `hostReportError` and the drain continues (Node prints the uncaught exception per-tick). Bounded by
/// the realm step limit (a runaway tick-enqueues-tick loop terminates as StepLimitExceeded, not a hang).
pub fn drainNextTicks(self: *Interpreter) EvalError!void {
    const host_timers = @import("host_timers.zig");
    while (self.next_tick_queue.items.len > 0) {
        const entry = self.next_tick_queue.orderedRemove(0);
        const c = try self.callFunction(entry.callback, entry.args, .undefined);
        if (c == .throw) host_timers.hostReportError(self, c.throw);
    }
}
