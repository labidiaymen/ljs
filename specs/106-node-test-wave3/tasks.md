# Tasks — Spec 106 node-test wave 3 (4 parallel agents)
- [x] A node:test runner (host_nodetest.zig): test/it/describe/hooks/mock; process.exit(1) on failure.
- [x] B timers + timers/promises (host_timers_mod.zig).
- [x] C vm (host_vm.zig): runInThisContext/runInNewContext/createContext/Script/compileFunction.
- [x] D url method surface (canParse/parse/legacy url) + STRONGER common shim (real mustCall
      verification via process.on('exit'), invalidArgTypeHelper, getArrayBufferViews, ...) + assert
      arrow-validator bug fix.
- [x] Integrated; build/test/lint/bench green; language 95.1%, 0 regressions.
- [x] Harness re-measured: 92/290 → **94/290 (32.4%)** NET. The stronger shim's REAL mustCall
      verification unmasked ~7 prior false-passes (buffer 30→28, process 22→19) while new coverage
      added ~9 (url 0→5, util 5→6, timers/vm/node:test) — so the headline is flat but the metric is now
      HONEST. node:test/vm/timers modules + the shim set up future waves. Remaining blockers: net/stream/
      http (libxev I/O slice), child_process/worker_threads, internal/* bindings.
