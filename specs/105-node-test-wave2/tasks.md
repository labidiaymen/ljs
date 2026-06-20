# Tasks — Spec 105 node-test wave 2 (4 parallel agents)
- [x] A path.posix/path.win32 (host_path.zig, Node lib/path.js port): node-test path 0/15 → 10/15.
- [x] B buffer module + indexOf/includes panic clamp + Buffer validation: buffer 5/63 → 26/63.
- [x] C process EventEmitter + hrtime/memoryUsage/exitCode/... (host_process.zig): process 8/91 → 21/91.
- [x] D querystring module + util/events small wins: querystring 0→3/3, util 3→5, events 0→2.
- [x] Integrated sequentially (host_require/bigint/interp_native additive conflicts unioned); build/test/lint/bench green.
- [ ] Re-measure harness total + record.
