# Tasks — Spec 098 Host event loop + timers

- [x] T1. Amend CLAUDE.md scope: Node host-runtime axis authorized (2026-06-20) + libxev-on-I/O note.
- [x] T2. `host_time.zig`: `monotonicMs()` + `sleepMs(ms)` (pure std, POSIX MONOTONIC / Windows QPC).
- [x] T3. `runtime_types.zig`: `NativeId.timer_fn` + `.console_log`.
- [x] T4. `interpreter.zig`: `timers` + `next_timer_id` (+ `host_out`/`host_err` shared writers).
- [x] T5. `host_timers.zig`: `timerFn` dispatch; `setTimeout`/`setInterval`/`clearTimeout`/
      `clearInterval`; `runEventLoop`; `consoleLog`. `TimerEntry` in `runtime_types.zig`.
- [x] T6. `builtins.zig`: four timer globals + a `console` object (`log`/`info`/`debug`/`warn`/`error`).
- [x] T7. `interp_native.zig`: dispatch `.timer_fn` + `.console_log` (+ the second-switch unreachable arm).
- [x] T8. `engine.zig`: `runHost(out, err)`; `main.zig`: `run` uses it (no trailing-value echo).
- [x] T9. Verified: ev1 `a,b,c-microtask,d-timeout` (ordering); ev2 interval×3 + clearInterval +
      clearTimeout all correct.
- [~] T10. Gate: build/test/lint/bench GREEN; full `language/` + `built-ins/` sweeps running (await
      0-regression result), then present at the commit gate (normal mode — await user validation).
