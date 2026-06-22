# Plan — Spec 117 async host context

## Files touched
- `src/interpreter.zig`: new `host_timer_parent: ?*Interpreter` field + `pub inline fn hostLoop()`.
- `src/interp_async.zig`: `asyncBodyThread` + `generatorBodyThread` body-`Interpreter` literals
  inherit `host_out`/`host_err`/`host_cwd`/`process_obj`/`host_start_ms`/`host_timer_parent`.
- `src/host_timers.zig`: `setImmediate`/`clearImmediate`/`schedule`/`cancel` use `self.hostLoop()`
  for the queue + id state.
- `src/host_setup.zig`: `process.nextTick` enqueues into `self.hostLoop().next_tick_queue`.
- `src/host_net.zig`: `startConnect` fast-fails a body-thread connect with an `'error'` (no hang).

## Constitution Check
- **Correctness leads:** the async path is core ECMA-262 — verified 0 Test262 language regressions
  (the suite exercises async/generators heavily). Host behavior verified by direct repros.
- **Perf gate:** `zig build bench` — no regression (changes are off the hot interpreter path;
  `hostLoop()` is one inlined optional load).
- **No race:** body/loop threads run cooperatively (one active at a time via the await handoff), so
  the shared root queues are touched by only one thread at any instant.

## Risk
- Touching `asyncBodyThread` is on the core async path — mitigated by the full Test262 differential.
- The socket-I/O stopgap is a documented fast-fail, not a silent change; removed when the marshaling
  cycle lands.
