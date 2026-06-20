# Tasks — Spec 104 assert + node-test harness
- [x] Unit A — `assert` module (`host_assert.zig`): full API + AssertionError + assert.strict;
      require('assert')/node:assert/assert/strict. All acceptance pass; 0 Test262 regressions.
- [x] Unit B — node-test harness: `scripts/vendor-node-test.sh` (pinned nodejs/node v22.16.0 →
      gitignored vendor/node-test/, modules buffer/events/util/path/url/querystring/assert/timers/
      process = 290 files), `scripts/run-node-tests.sh` (per-file ljs run → exit-code classify → per-
      module + total %), `scripts/node-test-common-shim.js`, `node-test.pin`, `.gitignore`.
- [x] Integrate both; build/test/lint/bench green.
- [x] FIRST measured Node-API conformance: 34/290 (11.7%) with --shim — assert 1/16, buffer 5/63,
      events 0/8, path 0/15 (blocked on path.posix/win32 namespaces), process 8/91, querystring 0/3,
      timers 17/55 (30.9%), url 0/13, util 3/26. Top blockers: 135 missing-module, 60 missing-method,
      25 real assertion diffs, 2 ENGINE PANICS (@intFromFloat out-of-bounds — latent crash). nodejs/node
      v22.16.0, run via `scripts/run-node-tests.sh --shim`.
