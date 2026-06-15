# Quickstart / Validation Guide: M0

How to prove M0 works end-to-end. Each step maps to a Success Criterion from
[spec.md](./spec.md). Commands assume repo root `~/ljs`.

## Prerequisites

- Zig **0.16.0** on PATH (`zig version` → `0.16.0`).
- Test262 vendored at the pinned commit:
  ```
  ./scripts/vendor-test262.sh        # clones tc39/test262 at the pinned commit into vendor/
  cat vendor/test262/.pinned-commit  # records the exact hash this run used
  ```

## 1. Build

```
zig build
```
Expected: builds the `ljs` executable with no errors on Zig 0.16.0 (constitution quality gate 1).

## 2. Minimal evaluation pipeline  → validates SC-005, US2

```
zig build run -- eval "1 + 2"          # → 3
zig build run -- eval "2 * (3 + 4)"    # → 14
zig build run -- eval "\"a\" + \"b\""  # → "ab"  (if string concat is in the trivial set)
zig build run -- eval "1 +"            # → SyntaxError on stderr, exit 1
```
Full trivial set (≥20 cases) is asserted by unit tests:
```
zig build test
```
Expected: all unit tests pass, including `eval_test.zig` (SC-005) and `metadata_test.zig`
(FR-002). No leaks reported by the testing allocator.

## 3. Conformance harness  → validates US1, SC-001

Run a small curated subset:
```
zig build test262 -- --path vendor/test262/test/language/expressions/addition
```
Expected: a summary line with `total/passed/failed/skipped/conformance%`. At M0 the pass rate
on real tests is ~0% **by design** (the harness helpers need language features M0 lacks — see
research.md D7); the point is that classification is correct.

Classification accuracy (SC-001) is asserted against a hand-curated sample by:
```
zig build test          # classify_test.zig compares harness output to manual labels
```
Expected: 100% match on the ≥20-file sample (positive, negative parse/runtime, `onlyStrict`,
and `includes`-using cases).

## 4. Fault isolation  → validates SC-002

```
zig build test262 -- --path tests/fixtures/faulty   # contains a step-limit/looping fixture
```
Expected: the run **completes**, reporting the faulty test as `fail (step_limit)` — it does not
hang or abort the run.

## 5. Determinism  → validates SC-003

```
zig build test262 -- --path vendor/test262/test/language/expressions/addition --report a.json
zig build test262 -- --path vendor/test262/test/language/expressions/addition --report b.json
diff a.json b.json     # → no differences
```

## 6. Baseline & regression detection  → validates US3, SC-004, SC-006

```
# record a baseline
zig build test262 -- --path <subset> --update-baseline baseline/<subset>.json

# clean run → exit 0
zig build test262 -- --path <subset> --baseline baseline/<subset>.json ; echo $?   # 0

# inject a regression (e.g. break a passing eval case), rebuild, re-run:
zig build test262 -- --path <subset> --baseline baseline/<subset>.json ; echo $?   # 1, lists regressed ids
```

## 7. Performance vs Node  → validates US4, SC-007/008/009

```
# compare ljs against Node on the shared benchmark set
zig build bench                       # prints ljs_ms / node_ms / ratio per case
zig build bench -- --update-baseline  # record bench/baseline.json

# regression check: slow a case down, rebuild, re-run:
zig build bench ; echo $?             # 1, flags the regressed case
```
Expected: a side-by-side ljs-vs-Node table from the first runnable build. The ratio to Node is
large (interpreter vs JIT) and is **reported, not failed**; only an ljs-vs-its-own-baseline
regression fails the gate. With Node absent, ljs is still timed and Node shows `n/a` (SC-009).

## Done = all of §2–§7 pass

These checks correspond 1:1 to SC-001…SC-009 and the four user stories. When they pass, M0 is
complete and the project has a working, reproducible **conformance gate and ljs-vs-Node
performance gate** to build M1 on.
