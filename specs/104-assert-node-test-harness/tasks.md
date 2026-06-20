# Tasks — Spec 104 assert + node-test harness
- [x] Unit A — `assert` module (`host_assert.zig`): full API + AssertionError + assert.strict;
      require('assert')/node:assert/assert/strict. All acceptance pass; 0 Test262 regressions.
- [x] Unit B — node-test harness: `scripts/vendor-node-test.sh` (pinned nodejs/node v22.16.0 →
      gitignored vendor/node-test/, modules buffer/events/util/path/url/querystring/assert/timers/
      process = 290 files), `scripts/run-node-tests.sh` (per-file ljs run → exit-code classify → per-
      module + total %), `scripts/node-test-common-shim.js`, `node-test.pin`, `.gitignore`.
- [x] Integrate both; build/test/lint/bench green.
- [ ] Run the harness on main (assert merged) → record the FIRST measured Node-API conformance number.
