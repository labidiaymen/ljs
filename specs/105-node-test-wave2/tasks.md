# Tasks — Spec 105 node-test wave 2 (4 parallel agents)
- [x] A path.posix/path.win32 (host_path.zig, Node lib/path.js port): node-test path 0/15 → 10/15.
- [x] B buffer module + indexOf/includes panic clamp + Buffer validation: buffer 5/63 → 26/63.
- [x] C process EventEmitter + hrtime/memoryUsage/exitCode/... (host_process.zig): process 8/91 → 21/91.
- [x] D querystring module + util/events small wins: querystring 0→3/3, util 3→5, events 0→2.
- [x] Integrated sequentially (host_require/bigint/interp_native additive conflicts unioned); build/test/lint/bench green.
- [x] node-test harness re-measured: 34/290 (11.7%) → **92/290 (31.7%)** with --shim. buffer 5→30,
      path 0→10, process 8→22, querystring 0→3, events 0→2, util 3→5, timers 19, assert 1, url 0.
      Language 95.1% conformance: ok, 0 regressions. (url + assert.throws-message-detail + the
      worker_threads/child_process/vm/net-blocked tests are the next buckets.)
