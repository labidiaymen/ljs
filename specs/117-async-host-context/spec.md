# Spec 117 — async/await + generators run correctly in host `run` mode

**Status:** Done (2026-06-22) — partial: non-I/O async fully fixed; socket-I/O-from-async-body
fast-fails with a clear error (full fix needs cross-thread libxev marshaling, a follow-up).
Conformance delta: **0 Test262 regressions** (language 42315 / 95.1% held — the async/generator path
is heavily exercised there and stayed green).

## Problem
Async function (and generator) bodies run on their OWN OS thread (`std.Thread.spawn` →
`asyncBodyThread`/`generatorBodyThread`), with a fresh `Interpreter` that shared only a few fields.
It did NOT inherit the host context — most importantly `host_out`/`host_err` — so `console.log`
inside ANY async body wrote to a null sink and was silently dropped. Worse, `setTimeout` /
`process.nextTick` scheduled inside an async body enqueued into the *body interpreter's* own queues
(never drained), so a `setTimeout`-based sleep inside an async function never fired.

Net effect: `(async()=>{console.log('x')})()`, `setTimeout(async()=>…)`,
`emitter.on('e', async()=>…)`, and `await new Promise(r=>setTimeout(r,ms))` all appeared dead in
host `run` mode. (Test262 async passed — it uses a different driver that never relies on host I/O.)

## Fix
1. The async + generator body-thread `Interpreter` now inherits `host_out`, `host_err`, `host_cwd`,
   `process_obj`, `host_start_ms`, and a new `host_timer_parent` pointer to the root (event-loop)
   interpreter.
2. New `Interpreter.hostLoop()` resolves "the interpreter that owns the timer/microtask/next-tick
   queues". `setTimeout`/`setInterval`/`setImmediate`/`clearTimeout`/`clearImmediate`/`nextTick`
   now schedule + cancel against `self.hostLoop()`, so work started inside a body thread reaches the
   loop. Safe without locks: the threads hand off cooperatively (only one runs at a time).

## Out of scope (follow-up cycle)
- **Socket I/O initiated INSIDE an async body** (the `await fetch()` case). libxev is single-threaded;
  a connect/write/close submitted from a body thread is never serviced by the loop thread and hangs.
  Stopgap: `startConnect` fast-fails such a connect with a clear `'error'` (so `fetch()` rejects
  instead of hanging) — `fetch().then(...)` initiated on the main turn remains the supported path.
  The real fix is cross-thread libxev submission marshaling (defer body-thread submits to the loop
  thread) or a stackless-async rewrite that removes the OS-thread-per-body model entirely.

## Acceptance (verified)
- `(async()=>{console.log('top-level async ran')})()` prints (was silent).
- `setTimeout(async()=>console.log('x'))` and `emitter.on('e', async…)` run their bodies.
- `await new Promise(r=>setTimeout(r,50))` (async sleep) resolves and continues.
- `await fetch(...)` from an async body rejects with a clear message (no hang); `fetch().then(...)`
  on the main turn still round-trips.
