//! HOST runtime (Node axis, spec 107 — NOT ECMA-262): the **libxev** I/O event loop bundled with the
//! interpreter. libxev (io_uring / kqueue / IOCP) is the macrotask / I-O layer that sits BENEATH the
//! ECMA-262 microtask (Promise-job) queue. This module owns the loop's lifecycle and the I/O-aware
//! "wait" the host event loop (`host_timers.runEventLoop`) uses when sockets are open.
//!
//! HOST-only and lazily created: the loop is allocated the first time an I/O handle (a `net` socket or
//! server) is opened. A timer-only or pure-compute script never creates a loop, so the established
//! pure-`std` timer path — and the entire Test262 / bench surface — is bit-for-bit unchanged
//! (`io_pending` stays 0 → `runEventLoop` never enters the I/O branch below).
//!
//! Integration rule (from the Node axis plan): after EVERY libxev callback that ran JS, the microtask
//! queue is drained before the next libxev event. We satisfy this by always returning control to the
//! top of `runEventLoop` (which drains nextTicks + microtasks) after each `tick`.
const xev = @import("xev");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_time = @import("host_time.zig");
const host_timers = @import("host_timers.zig");

/// The interpreter-owned libxev loop. Boxed (stable address) on the arena so completions referencing
/// `&loop` stay valid for the whole run.
pub const IoLoop = struct {
    loop: xev.Loop,
};

fn box(p: *anyopaque) *IoLoop {
    return @ptrCast(@alignCast(p));
}

/// The loop, creating it on first use. Bumps no counters — the caller manages `io_pending`.
/// Resolves to the ROOT (event-loop) interpreter so a submission from an async/generator BODY thread
/// targets the one loop `runEventLoop` drives — NOT a fresh orphan loop on the transient body interp.
pub fn ensureLoop(self: *Interpreter) EvalError!*xev.Loop {
    const root = self.hostLoop();
    if (root.io_loop) |p| return &box(p).loop;
    const io = root.arena.create(IoLoop) catch return error.OutOfMemory;
    io.* = .{ .loop = xev.Loop.init(.{}) catch return error.OutOfMemory };
    root.io_loop = io;
    return &io.loop;
}

/// The loop if it exists (no allocation), else null. Resolves to the root interpreter (see ensureLoop).
pub fn maybeLoop(self: *Interpreter) ?*xev.Loop {
    if (self.hostLoop().io_loop) |p| return &box(p).loop;
    return null;
}

/// Number of libxev operations currently armed by the `net` layer (`io_pending`). Maintained by
/// `host_net` (bumped at arm time, dropped on the `.disarm` completion) — a portable ref-count that,
/// unlike `loop.active`, is non-zero the moment an op is *submitted* (libxev only counts a completion
/// as active once it has *started*, during `run`). `runEventLoop` uses this to decide whether to keep
/// running / block on I/O. 0 off the host I/O path.
pub fn pendingIo(self: *Interpreter) usize {
    return self.io_pending;
}

/// One I/O-aware event-loop turn. Entered by `runEventLoop` ONLY when `io_pending > 0`. Processes
/// whatever libxev completions are immediately ready (non-blocking), fires a single due JS timer if
/// any, then blocks on I/O (or sleeps until the next timer) so the loop neither spins nor hangs. The
/// caller drains microtasks at the top of its next iteration, satisfying the drain-after-callback rule.
pub fn tick(self: *Interpreter) EvalError!void {
    const loop = maybeLoop(self) orelse return; // io_pending>0 with no loop shouldn't happen; be safe

    // 1. Process any completions that are ready right now, without blocking. A completion's callback
    //    may run JS (emit 'data'/'connect'/…), which can queue microtasks/timers or arm more I/O.
    //    A libxev run error here is a rare unrecoverable IOCP failure; bail out of this turn.
    loop.run(.no_wait) catch return;

    // 2. Timer phase: if a JS timer is due, fire exactly one (same single-fire-per-turn cadence as the
    //    pure-timer path), then return so microtasks drain before the next turn.
    if (host_timers.earliestDueIndex(self)) |idx| {
        const now = host_time.monotonicMs();
        const due = self.timers.items[idx].deadline_ms;
        if (due <= now) {
            try host_timers.fireTimer(self, idx);
            return;
        }
        // A timer is pending but not yet due: wait for it OR for I/O. libxev has no "run with timeout"
        // primitive, so when I/O is also in flight we poll in short slices (re-`tick` re-drains and
        // re-polls); when only timers remain we sleep precisely until the deadline.
        const remaining = due - now;
        if (self.io_pending > 0) {
            host_time.sleepMs(@min(remaining, 5));
        } else {
            host_time.sleepMs(remaining);
        }
        return;
    }

    // 3. No timers pending. If there is in-flight I/O, block until the next completion. If there is
    //    nothing pending at all (e.g. every open socket is paused) we have nothing to wait on — return
    //    and let `runEventLoop`'s liveness check end the loop rather than spin or block forever.
    if (self.io_pending > 0) {
        loop.run(.once) catch return;
    }
}
