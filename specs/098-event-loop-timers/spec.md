# Spec 098 — Host event loop + timers (setTimeout/setInterval) — Node axis, slice 1

Status: In progress
Owner: Aymen

## Context — opening the Node host-runtime axis

ljs reached **language 95.1%** (Test262 `language/`), the documented gate for starting the Node
host-runtime axis ([[ljs-node-axis-plan]]). This is a **charter expansion**: the project was
ECMAScript-only ("NO Node host APIs", with a stop-rule). The user explicitly authorized starting the
event loop (2026-06-20). CLAUDE.md scope is amended in the same cycle.

This is **slice 1** of the Node axis: the event-loop *structure* + HTML/Node **timers**. It is the
backbone every later host API (`fs`/`net`/`http`) bolts onto.

## Design

ECMA-262 defines the **microtask (Job) queue** — already in ljs (`job_queue` + `drainJobs`, drained
once after a script today). The **host** adds a **macrotask layer** (timers now; I/O later). The
integration rule (per the node-axis plan): **after every macrotask callback, drain the entire
microtask queue before the next macrotask.**

Event loop (`runEventLoop`), run by the CLI `ljs run` after the top-level script:
1. Drain microtasks (Promise reactions / await continuations).
2. If no active timers remain → done.
3. Find the earliest-deadline timer; sleep (real monotonic time) until it is due.
4. Fire every now-due timer in (deadline, insertion) order: call its callback; an `interval`
   reschedules (`deadline += delay`), a `timeout` is removed. Drain microtasks after each callback.
5. Repeat.

Determinism / Test262 isolation: the event loop is a **CLI/host-only** entry. The Test262 engine
surface (`evaluateWithLimit` / `evaluateAsyncTest`) is UNCHANGED — it still drains microtasks once and
never sleeps, so conformance and the deterministic test runner are unaffected. `setTimeout` et al. are
installed as ordinary global functions; if no host loop runs, a scheduled callback simply never fires
(same as a Test262 script that ignores them).

### Timers API (slice 1)
- `setTimeout(callback, delay=0, ...args)` → numeric id; schedules `callback(...args)` once after
  `delay` ms (coerced, clamped ≥ 0; non-callable first arg → TypeError).
- `setInterval(callback, delay=0, ...args)` → numeric id; repeats every `delay` ms.
- `clearTimeout(id)` / `clearInterval(id)` → cancel a pending timer by id (no-op on unknown/undefined).
- Ordering: a `setTimeout(…,0)` callback runs AFTER the current script + its microtasks; two timers
  with the same deadline run in insertion order. A microtask queued by a timer callback runs before
  the next timer.

### libxev (deferred)
The node-axis plan calls for **libxev** as the macrotask/timer/I-O layer. Slice 1 uses a **pure-std**
monotonic timer queue (`std.posix.clock_gettime(.MONOTONIC)` / Windows `QueryPerformanceCounter`),
so it adds **no external dependency yet** and stays testable. libxev is introduced in the **I/O
slice** (when `fs`/`net` need real multiplexing), where hand-rolling io_uring/IOCP is unjustifiable.
Recorded so the dependency lands with the work that needs it, not speculatively.

## Acceptance (Given/When/Then)

- **Given** `setTimeout(() => console.log("b"), 0); console.log("a");` run via `ljs run`, **Then**
  output is `a` then `b` (timer fires after the sync script).
- **Given** `Promise.resolve().then(()=>print("mt")); setTimeout(()=>print("to"),0);`, **Then** `mt`
  (microtask) prints before `to` (macrotask).
- **Given** `setInterval` + a `clearInterval` after N fires, **Then** it fires exactly N times then stops.
- **Given** `clearTimeout(id)` before the deadline, **Then** the callback never runs.
- **Given** two `setTimeout(…, 10)` registered in order, **Then** they fire in registration order.
- **Regression:** Test262 `language/` + `built-ins/` show 0 regressions (the host loop is not on the
  Test262 path); `build`/`test`/`lint`/`bench` green.

## Out of scope (later slices)
- libxev integration; `fs`/`net`/`http`; `process`/`Buffer`; CommonJS `require` / ESM host loading;
  `queueMicrotask` (could be a cheap add), `setImmediate`, `AbortController`. `console`/`print` host
  global if not already present is a minimal addition to make the timers observable.
