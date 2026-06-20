# Plan — Spec 098 Host event loop + timers

## Files touched
- `src/host_time.zig` (new) — `monotonicMs() f64` (pure std; POSIX CLOCK_MONOTONIC / Windows QPC) +
  `sleepMs(ms)`.
- `src/host_timers.zig` (new) — `TimerEntry`, the timer registry helpers, the native impls
  (`setTimeout`/`setInterval`/`clearTimeout`/`clearInterval`), and `runEventLoop(self)`.
- `src/runtime_types.zig` — `NativeId.timer_fn` (dispatch by `native_name`).
- `src/interpreter.zig` — `Interpreter` fields: `timers: std.ArrayListUnmanaged(TimerEntry) = .empty`,
  `next_timer_id: u64 = 1`. (Per-realm, like job_queue — pointer not needed since the host loop runs
  on the main interpreter; a timer callback's microtasks share the existing `job_queue`.)
- `src/builtins.zig` — register the four timer globals (native `timer_fn`, name set).
- `src/interp_native.zig` — dispatch `.timer_fn` → `host_timers.timerFn(self, name, args)`.
- `src/engine.zig` — `pub fn runHost(arena, source, mode)` : parse → run top-level → `runEventLoop`
  → map result. Leaves `evaluateWithLimit`/`evaluateAsyncTest` (Test262 path) UNCHANGED.
- `src/main.zig` — the `run` subcommand calls `runHost` (so timers fire); `eval` stays simple.
- A minimal `console.log` / `print` host global if not present (check first), to observe output.

## Design calls
- **Real monotonic time, pure std, no libxev** (slice 1). libxev deferred to the I/O slice (documented
  in spec). The loop `sleepMs`es until the next deadline — fine for a single-threaded host with only
  timers; I/O multiplexing (the libxev justification) is not in this slice.
- **Timer id** = monotonically increasing u64 (returned to JS as a Number). Cancellation marks an
  entry `cancelled`; the loop skips + compacts cancelled/finished entries.
- **A timer callback is invoked via the normal `callFunction`** (this = undefined); a throw from a
  callback is reported (host: print to stderr, continue the loop — Node prints an uncaught exception
  and, depending, exits; slice 1: print + continue, refine later).
- **Microtask interleaving**: `runEventLoop` calls `drainJobs` before sleeping and after each timer
  callback, so Promise/await continuations run at the right point.
- **Step watchdog**: the host loop is NOT step-bounded the way Test262 is (a server runs forever);
  but each callback's synchronous run still ticks the watchdog within a single turn. For slice 1 keep
  the per-callback step budget; the loop itself is bounded only by timers emptying.

## Constitution Check
- **Correctness-leads**: timer ordering + microtask-before-macrotask matches the HTML/Node event-loop
  model; cite the model in comments.
- **Perf no-regression gate**: the timer fields add two cheap fields to `Interpreter`; the Test262
  path never touches the event loop. Bench (ljs-vs-self) must stay green.
- **Conformance no-regression**: full `language/` + `built-ins/` sweeps, 0 regressions (the new globals
  are inert on the Test262 path).
- **Charter**: amend CLAUDE.md scope to authorize the Node host-runtime axis (user-authorized,
  2026-06-20), mirroring the prior UTF-16 / modules expansions.
