//! HOST runtime (Node axis, spec 098 — NOT ECMA-262): the timer globals
//! (`setTimeout`/`setInterval`/`clearTimeout`/`clearInterval`), `console.log`, and the **event loop**
//! that fires due timers with the microtask queue drained between callbacks. This layer is CLI/host
//! only — the Test262 engine surface never calls `runEventLoop`, so conformance is unaffected.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_time = @import("host_time.zig");

/// Dispatch the four timer globals (native `timer_fn`) by name. Inert unless the host event loop runs.
pub fn timerFn(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Completion {
    if (std.mem.eql(u8, name, "setTimeout")) return schedule(self, args, false);
    if (std.mem.eql(u8, name, "setInterval")) return schedule(self, args, true);
    if (std.mem.eql(u8, name, "clearTimeout")) return cancel(self, args);
    if (std.mem.eql(u8, name, "clearInterval")) return cancel(self, args);
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
    const id = self.next_timer_id;
    self.next_timer_id += 1;
    self.timers.append(self.arena, .{
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
    for (self.timers.items) |*t| {
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
        try self.drainJobs();
        compactCancelled(self);
        if (self.timers.items.len == 0) break;
        // Earliest-deadline timer.
        var min_idx: usize = 0;
        for (self.timers.items, 0..) |t, i| {
            if (t.deadline_ms < self.timers.items[min_idx].deadline_ms) min_idx = i;
        }
        const due = self.timers.items[min_idx].deadline_ms;
        const now = host_time.monotonicMs();
        if (due > now) host_time.sleepMs(due - now);
        // Snapshot the entry, then reschedule (interval) / remove (one-shot) BEFORE invoking — so a
        // `clearInterval(self)` inside the callback observes the still-present entry and cancels it.
        const entry = self.timers.items[min_idx];
        if (entry.interval_ms) |iv| {
            self.timers.items[min_idx].deadline_ms = host_time.monotonicMs() + @max(iv, 1);
        } else {
            _ = self.timers.orderedRemove(min_idx);
        }
        const c = try self.callFunction(entry.callback, entry.args, .undefined);
        if (c == .throw) printUncaught(self, c.throw);
    }
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

/// Print an uncaught timer-callback exception to stderr (best-effort; the loop continues).
fn printUncaught(self: *Interpreter, v: Value) void {
    const w = self.host_err orelse return;
    w.writeAll("Uncaught (in timer) ") catch return;
    v.writeDisplay(w) catch return;
    w.writeAll("\n") catch return;
    w.flush() catch return;
}
