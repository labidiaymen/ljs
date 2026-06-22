# Tasks — Spec 117 async host context

- [x] Diagnose: async body output lost → `host_out` not inherited by the body-thread Interpreter
- [x] Add `host_timer_parent` field + `hostLoop()` helper (interpreter.zig)
- [x] Inherit host I/O + process context in `asyncBodyThread` + `generatorBodyThread`
- [x] Redirect setTimeout/setInterval/setImmediate/clear* to `hostLoop()` (host_timers.zig)
- [x] Redirect `process.nextTick` to `hostLoop()` (host_setup.zig)
- [x] Verify: top-level async, async-from-timer, async-from-emitter, async sleep — all run
- [x] Fast-fail body-thread socket connect (host_net.zig) so `await fetch()` rejects vs hangs
- [x] Gate: test + lint + bench + Test262 language differential (0 regressions)
- [ ] (next cycle) cross-thread libxev marshaling → real `await fetch()` / async socket I/O
- [ ] (then) TLS → `https` / `fetch('https://…')`
