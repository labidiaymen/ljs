//! HOST runtime (Node axis, spec 106 — NOT ECMA-262): the `timers` and `timers/promises` core
//! modules. `require('timers')` re-exports the global scheduling functions as a module object (so
//! `require('timers').setTimeout === globalThis.setTimeout`) plus a `.promises` sub-namespace and the
//! legacy `enroll`/`unenroll`/`active`/`unref` stubs. `require('timers/promises')` IS that same
//! `.promises` object — `setTimeout(delay,value?,opts?)→Promise<value>`,
//! `setImmediate(value?,opts?)→Promise<value>`, `setInterval(delay,value?)→AsyncIterable<value>`, and
//! a `scheduler` with `wait(ms)`/`yield()`.
//!
//! Mechanics: a promise-resolving timer is a `.timers_method` native flagged `%settle%` carrying its
//! target promise (`%promise%`) + resolution value (`%value%`). It is registered as a one-shot timer
//! callback on the interpreter's existing timer queue; when the host event loop fires it, `method`
//! resolves the promise. Inert on the Test262 path (host core modules are not requireable there, and
//! the host event loop never runs on the conformance surface).
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_time = @import("host_time.zig");
const async_mod = @import("interp_async.zig");

// ════════════════════════════════════════════════════════════════════════════
//  module construction
// ════════════════════════════════════════════════════════════════════════════

/// Build `require('timers')`: the global timer functions re-exported, the legacy enroll/active/unref
/// stubs, and a `.promises` sub-namespace (identical to `require('timers/promises')`).
pub fn buildTimers(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());

    // Re-export the global scheduling natives so `require('timers').setTimeout === setTimeout`.
    const g = self.globals;
    for ([_][]const u8{ "setTimeout", "setInterval", "setImmediate", "clearTimeout", "clearInterval", "clearImmediate", "queueMicrotask" }) |name| {
        if (g) |env| {
            if (env.lookup(name)) |b| {
                try obj.defineData(name, b.value, true, false, true);
                continue;
            }
        }
    }

    // Legacy linked-list API stubs (enroll/unenroll/active/_unrefActive/unref) — minimal no-ops/
    // shape-fillers so the older `test-timers-*` that poke `_idleTimeout` don't crash on a missing fn.
    for ([_][]const u8{ "enroll", "unenroll", "active", "_unrefActive" }) |name|
        try defineMethod(self, obj, name);

    // `.promises` — the timers/promises namespace (cached so require('timers/promises') matches it).
    const promises = try buildPromises(self);
    try obj.defineData("promises", .{ .object = promises }, true, false, true);
    return obj;
}

/// Build the `timers/promises` namespace: promisified setTimeout/setImmediate, an async-iterable
/// setInterval, and a `scheduler` ({ wait, yield }).
fn buildPromises(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());
    for ([_][]const u8{ "setTimeout", "setImmediate", "setInterval" }) |name|
        try defineMethod(self, obj, name);

    // scheduler.wait(ms[,opts]) / scheduler.yield() — the WHATWG scheduler subset.
    const scheduler = try Object.create(arena, self.objectProto());
    for ([_][]const u8{ "wait", "yield" }) |name|
        try defineMethod(self, scheduler, name);
    try obj.defineData("scheduler", .{ .object = scheduler }, true, false, true);
    return obj;
}

/// Define a `.timers_method` native `name` on `target` (configurable, non-enumerable own data prop).
fn defineMethod(self: *Interpreter, target: *Object, name: []const u8) EvalError!void {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .timers_method, name);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("name", .{ .string = name }, false, false, true);
    try target.defineData(name, .{ .object = fn_obj }, true, false, true);
}

// ════════════════════════════════════════════════════════════════════════════
//  dispatch
// ════════════════════════════════════════════════════════════════════════════

/// Dispatch a `.timers_method` native by `native_name` (+ hidden own state for the settle/iterator
/// callbacks).
pub fn method(self: *Interpreter, func: *Object, args: []const Value) EvalError!Completion {
    const eq = std.mem.eql;
    const name = func.native_name;

    // Internal promise-settling timer callback (fired by the event loop): resolve `%promise%` with
    // `%value%`. An async-iterator step additionally yields a `{ value, done:false }` result object.
    if (func.get("%settle%") != null) return settle(self, func);
    // Async-iterator methods for setInterval's iterable.
    if (eq(u8, name, "%next%")) return intervalNext(self, func);
    if (eq(u8, name, "%return%")) return intervalReturn(self, func);
    if (eq(u8, name, "%asyncIterator%")) {
        // [Symbol.asyncIterator]() returns the iterable itself (stashed on `%iter%`).
        const iv = func.get("%iter%") orelse return .{ .normal = .undefined };
        return .{ .normal = iv };
    }

    if (eq(u8, name, "setTimeout")) return promiseSetTimeout(self, args);
    if (eq(u8, name, "setImmediate")) return promiseSetImmediate(self, args);
    if (eq(u8, name, "setInterval")) return promiseSetInterval(self, args);
    if (eq(u8, name, "wait")) return schedulerWait(self, args);
    if (eq(u8, name, "yield")) return schedulerYield(self);

    // Legacy enroll/active/unref stubs.
    if (eq(u8, name, "enroll")) return enroll(self, args);
    if (eq(u8, name, "unenroll")) return unenroll(self, args);
    if (eq(u8, name, "active") or eq(u8, name, "_unrefActive")) return active(args);

    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  timers/promises — setTimeout / setImmediate
// ════════════════════════════════════════════════════════════════════════════

/// `timersPromises.setTimeout(delay=1, value?, opts?)` → a Promise resolved with `value` after a
/// one-shot timer fires. A pre-aborted `{ signal }` rejects synchronously with an AbortError.
fn promiseSetTimeout(self: *Interpreter, args: []const Value) EvalError!Completion {
    const delay = try delayOf(self, if (args.len > 0) args[0] else .undefined);
    if (delay.isAbrupt()) return delay;
    const value: Value = if (args.len > 1) args[1] else .undefined;
    const opts: Value = if (args.len > 2) args[2] else .undefined;

    const promise = try async_mod.newPromise(self);
    if (try abortedReject(self, promise, opts)) return .{ .normal = .{ .object = promise } };

    try scheduleSettle(self, promise, value, delay.normal.number, false);
    return .{ .normal = .{ .object = promise } };
}

/// `timersPromises.setImmediate(value?, opts?)` → a Promise resolved with `value` on the next check
/// phase. Implemented as a 0ms one-shot timer (the loop drains microtasks between phases either way).
fn promiseSetImmediate(self: *Interpreter, args: []const Value) EvalError!Completion {
    const value: Value = if (args.len > 0) args[0] else .undefined;
    const opts: Value = if (args.len > 1) args[1] else .undefined;

    const promise = try async_mod.newPromise(self);
    if (try abortedReject(self, promise, opts)) return .{ .normal = .{ .object = promise } };

    try scheduleSettle(self, promise, value, 0, false);
    return .{ .normal = .{ .object = promise } };
}

/// Register a one-shot timer whose callback resolves `promise` with `value` (the `%settle%` native).
/// When `done` is set the resolution value is an iterator result `{ value, done:false }` instead.
fn scheduleSettle(self: *Interpreter, promise: *Object, value: Value, delay: f64, iter_result: bool) EvalError!void {
    const arena = self.arena;
    const cb = try Object.createNative(arena, .timers_method, "");
    cb.prototype = self.functionProto();
    _ = cb.properties.orderedRemove("prototype");
    try cb.defineData("%settle%", .{ .boolean = true }, false, false, true);
    try cb.defineData("%promise%", .{ .object = promise }, false, false, true);
    try cb.defineData("%value%", value, false, false, true);
    if (iter_result) try cb.defineData("%iter%", .{ .boolean = true }, false, false, true);

    const id = self.next_timer_id;
    self.next_timer_id += 1;
    self.timers.append(arena, .{
        .id = id,
        .callback = cb,
        .args = &.{},
        .deadline_ms = host_time.monotonicMs() + @max(delay, 0),
        .interval_ms = null,
    }) catch return error.OutOfMemory;
}

/// The `%settle%` timer callback: resolve `%promise%` with `%value%` (or an iterator result wrapping
/// it). A promise already settled (e.g. a prior `.return()`) is a no-op (resolvePromise guards it).
fn settle(self: *Interpreter, func: *Object) EvalError!Completion {
    const pv = func.get("%promise%") orelse return .{ .normal = .undefined };
    if (pv != .object or pv.object.promise == null) return .{ .normal = .undefined };
    const value = func.get("%value%") orelse .undefined;
    if (func.get("%iter%") != null) {
        const result = try iterResult(self, value, false);
        try async_mod.resolvePromise(self, pv.object, .{ .object = result });
    } else {
        try async_mod.resolvePromise(self, pv.object, value);
    }
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  timers/promises — setInterval (async iterable)
// ════════════════════════════════════════════════════════════════════════════

/// `timersPromises.setInterval(delay=1, value?, opts?)` → an async iterable. Each `.next()` schedules
/// a one-shot timer (period `delay`) resolving to `{ value, done:false }`; `.return()` ends it.
fn promiseSetInterval(self: *Interpreter, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const delay = try delayOf(self, if (args.len > 0) args[0] else .undefined);
    if (delay.isAbrupt()) return delay;
    const value: Value = if (args.len > 1) args[1] else .undefined;

    // The iterable object: `[Symbol.asyncIterator]()` → itself, with `.next`/`.return`.
    const iter = try Object.create(arena, self.objectProto());
    try iter.defineData("%delay%", .{ .number = delay.normal.number }, false, false, true);
    try iter.defineData("%value%", value, false, false, true);
    try iter.defineData("%done%", .{ .boolean = false }, false, false, true);

    try defineBound(self, iter, "next", "%next%");
    try defineBound(self, iter, "return", "%return%");

    // [Symbol.asyncIterator] — a method returning the iterable itself.
    const ait = try Object.createNative(arena, .timers_method, "%asyncIterator%");
    ait.prototype = self.functionProto();
    _ = ait.properties.orderedRemove("prototype");
    try ait.defineData("%iter%", .{ .object = iter }, false, false, true);
    if (self.wellKnownSymbol("asyncIterator")) |sym| {
        try iter.defineSymbolData(sym, .{ .object = ait }, true, false, true);
    }
    return .{ .normal = .{ .object = iter } };
}

/// Define a `.timers_method` native `prop` on `iter` whose `native_name` is `internal` and which
/// carries the owning iterable via a hidden `%iter%` (so the method reads the iterable's state).
fn defineBound(self: *Interpreter, iter: *Object, prop: []const u8, internal: []const u8) EvalError!void {
    const arena = self.arena;
    const fn_obj = try Object.createNative(arena, .timers_method, internal);
    fn_obj.prototype = self.functionProto();
    _ = fn_obj.properties.orderedRemove("prototype");
    try fn_obj.defineData("%iter%", .{ .object = iter }, false, false, true);
    try fn_obj.defineData("name", .{ .string = prop }, false, false, true);
    try iter.defineData(prop, .{ .object = fn_obj }, true, false, true);
}

/// `iterator.next()` — return a Promise resolving to `{ value, done:false }` after one period (or to
/// `{ value:undefined, done:true }` immediately once `.return()` has ended the iterable).
fn intervalNext(self: *Interpreter, func: *Object) EvalError!Completion {
    const iv = func.get("%iter%") orelse return .{ .normal = .undefined };
    if (iv != .object) return .{ .normal = .undefined };
    const iter = iv.object;
    const promise = try async_mod.newPromise(self);

    const done_v: Value = iter.get("%done%") orelse .{ .boolean = false };
    if (done_v == .boolean and done_v.boolean) {
        const result = try iterResult(self, .undefined, true);
        try async_mod.resolvePromise(self, promise, .{ .object = result });
        return .{ .normal = .{ .object = promise } };
    }
    const value = iter.get("%value%") orelse .undefined;
    const delay_v: Value = iter.get("%delay%") orelse .{ .number = 1 };
    const delay: f64 = if (delay_v == .number) delay_v.number else 1;
    try scheduleSettle(self, promise, value, delay, true);
    return .{ .normal = .{ .object = promise } };
}

/// `iterator.return()` — mark the iterable done and return a resolved `{ value:undefined, done:true }`
/// Promise.
fn intervalReturn(self: *Interpreter, func: *Object) EvalError!Completion {
    const iv = func.get("%iter%") orelse return .{ .normal = .undefined };
    if (iv == .object) try iv.object.defineData("%done%", .{ .boolean = true }, false, false, true);
    const promise = try async_mod.newPromise(self);
    const result = try iterResult(self, .undefined, true);
    try async_mod.resolvePromise(self, promise, .{ .object = result });
    return .{ .normal = .{ .object = promise } };
}

/// Build a `{ value, done }` IteratorResult object.
fn iterResult(self: *Interpreter, value: Value, done: bool) EvalError!*Object {
    const obj = try Object.create(self.arena, self.objectProto());
    try obj.defineData("value", value, true, true, true);
    try obj.defineData("done", .{ .boolean = done }, true, true, true);
    return obj;
}

// ════════════════════════════════════════════════════════════════════════════
//  timers/promises — scheduler
// ════════════════════════════════════════════════════════════════════════════

/// `scheduler.wait(ms[,opts])` → `timersPromises.setTimeout(ms, undefined, opts)`.
fn schedulerWait(self: *Interpreter, args: []const Value) EvalError!Completion {
    const delay = try delayOf(self, if (args.len > 0) args[0] else .undefined);
    if (delay.isAbrupt()) return delay;
    const opts: Value = if (args.len > 1) args[1] else .undefined;
    const promise = try async_mod.newPromise(self);
    if (try abortedReject(self, promise, opts)) return .{ .normal = .{ .object = promise } };
    try scheduleSettle(self, promise, .undefined, delay.normal.number, false);
    return .{ .normal = .{ .object = promise } };
}

/// `scheduler.yield()` → a Promise resolved on the next event-loop turn (a 0ms timer — yields control
/// to already-queued work before continuing).
fn schedulerYield(self: *Interpreter) EvalError!Completion {
    const promise = try async_mod.newPromise(self);
    try scheduleSettle(self, promise, .undefined, 0, false);
    return .{ .normal = .{ .object = promise } };
}

// ════════════════════════════════════════════════════════════════════════════
//  legacy enroll / active stubs
// ════════════════════════════════════════════════════════════════════════════

/// `timers.enroll(item, msecs)` — validate `msecs` (Node throws ERR_INVALID_ARG_TYPE / ERR_OUT_OF_
/// RANGE), then stash `_idleTimeout`/`_idleNext`/`_idlePrev` on the item.
fn enroll(self: *Interpreter, args: []const Value) EvalError!Completion {
    const item: Value = if (args.len > 0) args[0] else .undefined;
    const msecs: Value = if (args.len > 1) args[1] else .undefined;
    // ToNumber-ish validation, mirroring Node's `validateNumber`/`getTimerDuration`.
    if (msecs != .number) return nodeError(self, "TypeError", "ERR_INVALID_ARG_TYPE", "The \"msecs\" argument must be of type number");
    const m = msecs.number;
    if (std.math.isNan(m) or std.math.isInf(m) or m < 0)
        return nodeError(self, "RangeError", "ERR_OUT_OF_RANGE", try outOfRangeMsg(self, m));
    if (item != .object) return .{ .normal = .undefined };
    try item.object.defineData("_idleTimeout", .{ .number = m }, true, true, true);
    return .{ .normal = .undefined };
}

/// `timers.unenroll(item)` — reset `_idleTimeout` to -1 (Node's "not enrolled" sentinel).
fn unenroll(self: *Interpreter, args: []const Value) EvalError!Completion {
    _ = self;
    const item: Value = if (args.len > 0) args[0] else .undefined;
    if (item == .object) try item.object.defineData("_idleTimeout", .{ .number = -1 }, true, true, true);
    return .{ .normal = .undefined };
}

/// `timers.active(item)` / `timers._unrefActive(item)` — stamp the idle bookkeeping fields Node sets
/// when (re)activating a timer. Only mutates an item whose `_idleTimeout >= 0` (Node ignores bogus).
fn active(args: []const Value) EvalError!Completion {
    const item: Value = if (args.len > 0) args[0] else .undefined;
    if (item != .object) return .{ .normal = .undefined };
    const obj = item.object;
    const to = obj.get("_idleTimeout") orelse return .{ .normal = .undefined };
    if (to != .number or to.number < 0) return .{ .normal = .undefined };
    try obj.defineData("_idleStart", .{ .number = @round(host_time.monotonicMs()) }, true, true, true);
    // _idleNext/_idlePrev are linked-list pointers; Node's tests only assert they are truthy.
    if (obj.get("_idleNext") == null) try obj.defineData("_idleNext", .{ .object = obj }, true, true, true);
    if (obj.get("_idlePrev") == null) try obj.defineData("_idlePrev", .{ .object = obj }, true, true, true);
    return .{ .normal = .undefined };
}

// ════════════════════════════════════════════════════════════════════════════
//  helpers
// ════════════════════════════════════════════════════════════════════════════

/// ToNumber(delay), clamped to >= 0 (NaN/negative → 0), matching the HTML timer-init steps. Returns an
/// abrupt completion if ToNumber throws.
fn delayOf(self: *Interpreter, v: Value) EvalError!Completion {
    if (v == .undefined) return .{ .normal = .{ .number = 1 } };
    const nd = try self.toNumberV(v);
    if (nd.isAbrupt()) return nd;
    var d = nd.normal.number;
    if (std.math.isNan(d) or d < 0) d = 0;
    return .{ .normal = .{ .number = d } };
}

/// If `opts` is `{ signal }` with an already-aborted signal, reject `promise` with an AbortError and
/// return true (the caller returns the rejected promise). Otherwise false (a live signal is ignored —
/// there is no event-driven abort wiring in this slice). `AbortController`/`AbortSignal` globals are
/// not installed, so the aborted-in-advance branch is the only reachable abort path.
fn abortedReject(self: *Interpreter, promise: *Object, opts: Value) EvalError!bool {
    if (opts != .object) return false;
    const sig = opts.object.get("signal") orelse return false;
    if (sig != .object) return false;
    const aborted = sig.object.get("aborted") orelse return false;
    if (aborted == .boolean and aborted.boolean) {
        const err = try makeAbortError(self);
        try async_mod.rejectPromise(self, promise, .{ .object = err });
        return true;
    }
    return false;
}

/// Build an `AbortError` (Node: name "AbortError", code "ABORT_ERR", a fixed message).
fn makeAbortError(self: *Interpreter) EvalError!*Object {
    const err = try Object.create(self.arena, self.errorProto("Error"));
    err.error_data = true;
    try err.set("name", .{ .string = "AbortError" });
    try err.set("message", .{ .string = "The operation was aborted" });
    try err.defineData("code", .{ .string = "ABORT_ERR" }, true, false, true);
    return err;
}

/// Build + throw a Node-style typed error (a `name`-class Error carrying a `code` property).
fn nodeError(self: *Interpreter, comptime kind: []const u8, code: []const u8, msg: []const u8) EvalError!Completion {
    const err = try Object.create(self.arena, self.errorProto(kind));
    err.error_data = true;
    try err.set("name", .{ .string = kind });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = code }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

/// Node's ERR_OUT_OF_RANGE message for `enroll`'s msecs (matches `test-timers-enroll-invalid-msecs`).
fn outOfRangeMsg(self: *Interpreter, m: f64) EvalError![]const u8 {
    const num = try self.toStringValuePub(.{ .number = m });
    const received = if (num.isAbrupt()) "NaN" else num.normal.string;
    return std.fmt.allocPrint(
        self.arena,
        "The value of \"msecs\" is out of range. It must be a non-negative finite number. Received {s}",
        .{received},
    ) catch return error.OutOfMemory;
}
