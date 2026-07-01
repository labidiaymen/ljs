# Tasks: time API

## Phase 1

- [x] T1 Added `"time"` to the parser's `isStdNamespace` list. New
  `timeCallType` in `lumen_check_stdlib.zig`, wired into `staticCallType`.
- [x] T2 `time.now()` -- `() -> i64`, milliseconds since epoch via the
  real clock.
- [x] T3 `time.monotonic()` -- `() -> i64`, milliseconds via the awake/
  monotonic clock.
- [x] T4 Verified: `time.now()` returned `1782924078827` (~2026, a
  plausible current-era value); two `time.monotonic()` calls showed
  `t2 >= t1` true and a `0`ms difference (correct for two back-to-back
  calls with no work between them). Found and worked around a real,
  separate, pre-existing limitation while writing the test: `i64` values
  can't be compared/used in arithmetic directly against int literals
  (`n > 1700000000000` and even `diff >= 0` both failed to type-check) --
  routed around it by keeping every comparison strictly `i64` op `i64`.
  Confirmed identical output under `--wasm` via wasmtime, not just
  compile-checked.
- [x] T5 `zig build test` passes. `zig build conformance` run clean.
- [x] T6 Updated `website/stdlib.html`: new `time` quick-jump list +
  function blocks; updated the Planned table's "time · http" row to drop
  `time`, keeping only the still-planned `http.get`.
- [x] T7 Commit, push, redeploy `lumen-playground`.
