//! HOST runtime (Node axis, spec 098 — NOT ECMA-262): the timer globals
//! (`setTimeout`/`setInterval`/`clearTimeout`/`clearInterval`), `console.log`, and the **event loop**
//! that fires due timers with the microtask queue drained between callbacks. This layer is CLI/host
//! only — the Test262 engine surface never calls `runEventLoop`, so conformance is unaffected.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_time = @import("host_time.zig");
const host_setup = @import("host_setup.zig");
const host_io = @import("host_io.zig");

/// Dispatch the host scheduling globals (native `timer_fn`) by name. Inert unless the event loop runs.
pub fn timerFn(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "setTimeout")) return schedule(self, args, false);
    if (std.mem.eql(u8, name, "setInterval")) return schedule(self, args, true);
    if (std.mem.eql(u8, name, "clearTimeout")) return cancel(self, args);
    if (std.mem.eql(u8, name, "clearInterval")) return cancel(self, args);
    if (std.mem.eql(u8, name, "queueMicrotask")) return queueMicrotask(self, args);
    if (std.mem.eql(u8, name, "setImmediate")) return setImmediate(self, args);
    if (std.mem.eql(u8, name, "clearImmediate")) return clearImmediate(self, args);
    return .{ .normal = .undefined };
}

/// `queueMicrotask(callback)` (WHATWG/Node): enqueue a microtask calling `callback()` on the SAME Job
/// queue as Promise reactions (FIFO interleave). A non-callable argument is a TypeError.
fn queueMicrotask(self: *Interpreter, args: []const Value) EvalError!Completion {
    const cb = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or cb.object.kind != .function)
        return self.throwError("TypeError", "queueMicrotask requires a callback function");
    if (self.job_queue) |q| q.append(self.arena, .{ .microtask = cb.object }) catch return error.OutOfMemory;
    return .{ .normal = .undefined };
}

/// `setImmediate(callback, ...args)` (Node): queue a check-phase task; returns its numeric id.
fn setImmediate(self: *Interpreter, args: []const Value) EvalError!Completion {
    const cb = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or cb.object.kind != .function)
        return self.throwError("TypeError", "callback is not a function");
    const extra: []const Value = if (args.len > 1) try self.arena.dupe(Value, args[1..]) else &.{};
    const loop = self.hostLoop();
    const id = loop.next_immediate_id;
    loop.next_immediate_id += 1;
    loop.immediates.append(self.arena, .{ .id = id, .callback = cb.object, .args = extra }) catch return error.OutOfMemory;
    return .{ .normal = .{ .number = @floatFromInt(id) } };
}

/// `clearImmediate(id)` (Node): cancel a pending immediate (no-op if unknown/undefined).
fn clearImmediate(self: *Interpreter, args: []const Value) EvalError!Completion {
    if (args.len == 0) return .{ .normal = .undefined };
    const nd = try self.toNumberV(args[0]);
    if (nd.isAbrupt()) return nd;
    if (std.math.isNan(nd.normal.number)) return .{ .normal = .undefined };
    const id: u64 = @intFromFloat(@max(nd.normal.number, 0));
    for (self.hostLoop().immediates.items) |*im| {
        if (im.id == id) {
            im.cancelled = true;
            break;
        }
    }
    return .{ .normal = .undefined };
}

/// `setTimeout(cb, delay=0, ...args)` / `setInterval(...)`: register a timer, return its numeric id.
fn schedule(self: *Interpreter, args: []const Value, repeat: bool) EvalError!Completion {
    const cb = if (args.len > 0) args[0] else .undefined;
    if (cb != .object or cb.object.kind != .function)
        return self.throwError("TypeError", "callback is not a function");
    // Delay = ToNumber(arg[1]); NaN / negative clamp to 0 (HTML "timer initialization" steps).
    var delay: f64 = 0;
    if (args.len > 1) {
        const nd = try self.toNumberV(args[1]);
        if (nd.isAbrupt()) return nd;
        delay = nd.normal.number;
        if (std.math.isNan(delay) or delay < 0) delay = 0;
    }
    const extra: []const Value = if (args.len > 2) try self.arena.dupe(Value, args[2..]) else &.{};
    const loop = self.hostLoop();
    const id = loop.next_timer_id;
    loop.next_timer_id += 1;
    loop.timers.append(self.arena, .{
        .id = id,
        .callback = cb.object,
        .args = extra,
        .deadline_ms = host_time.monotonicMs() + delay,
        .interval_ms = if (repeat) delay else null,
    }) catch return error.OutOfMemory;
    return .{ .normal = .{ .number = @floatFromInt(id) } };
}

/// `clearTimeout(id)` / `clearInterval(id)`: cancel the matching pending timer (no-op if unknown).
fn cancel(self: *Interpreter, args: []const Value) EvalError!Completion {
    if (args.len == 0) return .{ .normal = .undefined };
    const nd = try self.toNumberV(args[0]);
    if (nd.isAbrupt()) return nd;
    const id_f = nd.normal.number;
    if (std.math.isNan(id_f)) return .{ .normal = .undefined };
    const id: u64 = @intFromFloat(@max(id_f, 0));
    for (self.hostLoop().timers.items) |*t| {
        if (t.id == id) {
            t.cancelled = true;
            break;
        }
    }
    return .{ .normal = .undefined };
}

/// HOST event loop: drain microtasks, then fire the earliest due timer (sleeping until its deadline on
/// the monotonic clock), draining microtasks again before the next timer — the HTML/Node ordering
/// (microtasks empty between macrotasks). Runs until the timer queue empties. A timer callback that
/// throws prints an uncaught-exception line to stderr and the loop continues (slice 1; refine later).
pub fn runEventLoop(self: *Interpreter) EvalError!void {
    while (true) {
        // 0. nextTick queue drains FULLY first (Node: ticks run before each microtask checkpoint, so a
        //    nextTick callback precedes any Promise reaction scheduled the same turn). Ticks may enqueue
        //    more ticks AND microtasks; this drains to empty before the microtask drain below.
        try host_setup.drainNextTicks(self);
        // 1. Microtasks always drain to empty first (Promise reactions + queueMicrotask).
        try self.drainJobs();
        // 2. Check phase: run ONE pending immediate (then loop → re-drain microtasks). An immediate
        //    queued during a callback runs on a later turn, not re-entrantly.
        if (popImmediate(self)) |imm| {
            const c = try self.callFunction(imm.callback, imm.args, .undefined);
            if (c == .throw) hostReportError(self, c.throw);
            continue;
        }
        // 3. Timer + I/O phase.
        compactCancelled(self);
        // Liveness: keep running while a timer is pending OR libxev I/O is in flight OR more work was
        // queued. The microtask drain (step 1) can schedule NEW nextTicks/immediates (e.g. a stream's
        // auto-resume flush when a consumer attaches a late 'data' listener — node-fetch's body consume);
        // those must be processed, not dropped, so include them in the liveness test.
        if (self.timers.items.len == 0 and host_io.pendingIo(self) == 0 and
            self.next_tick_queue.items.len == 0 and self.immediates.items.len == 0) break;
        // If only ticks/immediates remain (no timers, no I/O in flight), loop back to drain them at the
        // top — DON'T fall through to the timer path below, which assumes `timers.len > 0`.
        if (self.timers.items.len == 0 and host_io.pendingIo(self) == 0) continue;
        // When libxev operations are in flight, route the wait through the I/O-aware tick (which also
        // fires a due timer). This branch is never taken off the host I/O path (no loop → 0 pending).
        if (host_io.pendingIo(self) > 0) {
            try host_io.tick(self);
            continue;
        }
        // Pure-timer path (no I/O in flight) — `timers.len > 0` is guaranteed by the break above.
        const idx = earliestDueIndex(self).?;
        const due = self.timers.items[idx].deadline_ms;
        const now = host_time.monotonicMs();
        if (due > now) {
            host_time.sleepMs(due - now); // nothing else runnable; wait for the next timer
            continue;
        }
        try fireTimer(self, idx);
    }
}

/// Index of the timer with the earliest deadline, or null if the queue is empty. (Shared by the
/// pure-timer path here and the I/O-aware `host_io.tick`.)
pub fn earliestDueIndex(self: *Interpreter) ?usize {
    if (self.timers.items.len == 0) return null;
    var min_idx: usize = 0;
    for (self.timers.items, 0..) |t, i| {
        if (t.deadline_ms < self.timers.items[min_idx].deadline_ms) min_idx = i;
    }
    return min_idx;
}

/// Fire the timer at `idx`: reschedule (interval) / remove (one-shot) BEFORE invoking — so a
/// `clearInterval(self)` inside the callback observes the still-present entry and cancels it — then
/// call the callback, reporting an uncaught throw to stderr (the loop continues).
pub fn fireTimer(self: *Interpreter, idx: usize) EvalError!void {
    const entry = self.timers.items[idx];
    if (entry.interval_ms) |iv| {
        self.timers.items[idx].deadline_ms = host_time.monotonicMs() + @max(iv, 1);
    } else {
        _ = self.timers.orderedRemove(idx);
    }
    const c = try self.callFunction(entry.callback, entry.args, .undefined);
    if (c == .throw) hostReportError(self, c.throw);
}

/// Pop the first non-cancelled immediate (FIFO), discarding cancelled ones; null if none remain.
fn popImmediate(self: *Interpreter) ?object_mod.ImmediateEntry {
    while (self.immediates.items.len > 0) {
        const im = self.immediates.orderedRemove(0);
        if (!im.cancelled) return im;
    }
    return null;
}

/// Drop cancelled timers from the queue (compaction; preserves relative order of the survivors).
fn compactCancelled(self: *Interpreter) void {
    var i: usize = 0;
    while (i < self.timers.items.len) {
        if (self.timers.items[i].cancelled) {
            _ = self.timers.orderedRemove(i);
        } else i += 1;
    }
}

/// HOST `console.log(...)`: write the space-joined ToString of the arguments + a newline to stdout
/// (the run's shared writer, flushed per line so output is timely under intervals). ToString runs
/// FIRST (it can throw / run getters) so a coercion error propagates before any partial write.
pub fn consoleLog(self: *Interpreter, args: []const Value) EvalError!Completion {
    const w = self.host_out orelse return .{ .normal = .undefined };
    // Build the whole line first (ToString can throw / run getters), then write once.
    var line: std.ArrayListUnmanaged(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i > 0) line.append(self.arena, ' ') catch return error.OutOfMemory;
        const sc = try self.toStringValuePub(a);
        if (sc.isAbrupt()) return sc;
        line.appendSlice(self.arena, sc.normal.string) catch return error.OutOfMemory;
    }
    line.append(self.arena, '\n') catch return error.OutOfMemory;
    // A write/flush failure (e.g. a closed stdout pipe) ends logging but must not abort the script.
    w.writeAll(line.items) catch return .{ .normal = .undefined };
    w.flush() catch return .{ .normal = .undefined };
    return .{ .normal = .undefined };
}

/// HOST HostReportErrors: print an uncaught host-callback exception (timer / queueMicrotask) to
/// stderr, best-effort; the event loop / microtask drain continues. Shared by `runEventLoop` and
/// `drainJobs` (the queueMicrotask path).
pub fn hostReportError(self: *Interpreter, v: Value) void {
    const w = self.host_err orelse return;
    // For an Error, print its V8 stack trace (like Node prints an uncaught exception), else the value.
    if (v == .object and v.object.error_data) {
        if (@import("error_stack.zig").buildStringOnly(self, v.object)) |s| {
            w.writeAll(s) catch return;
            w.writeAll("\n") catch return;
            w.flush() catch return;
            return;
        }
    }
    w.writeAll("Uncaught ") catch return;
    v.writeDisplay(w) catch return;
    w.writeAll("\n") catch return;
    w.flush() catch return;
}
