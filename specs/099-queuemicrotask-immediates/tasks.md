# Tasks — Spec 099 queueMicrotask + immediates

- [x] T1. `runtime_types.zig`: `Job.microtask: *Object` variant; `ImmediateEntry` type (+ object.zig re-export).
- [x] T2. `interp_async.zig` `drainJobs`: handle `.microtask` (call cb; report a throw via hostReportError).
- [x] T3. `interpreter.zig`: `immediates` + `next_immediate_id`.
- [x] T4. Routed `queueMicrotask`/`setImmediate`/`clearImmediate` through `timer_fn` dispatch.
- [x] T5. `host_timers.zig`: `queueMicrotask` (TypeError if not callable), `setImmediate`/
      `clearImmediate`; `runEventLoop` restructured to the phase model (microtask → immediate → timer);
      `hostReportError` made pub + shared.
- [x] T6. `builtins.zig`: registered the three new globals.
- [x] T7. Verified: `sync → promise/queueMicrotask → immediate → timeout 0`; clearImmediate cancels;
      `queueMicrotask(5)` → TypeError.
- [~] T8. Gate: build/test/lint/bench GREEN; 0 Test262 refs to the new globals + `.microtask` is an
      additive switch arm (inert on the Test262 path); language baseline check running; present at gate.
