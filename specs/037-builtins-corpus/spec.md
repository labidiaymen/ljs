# M37 — Expand the conformance corpus to `built-ins/` + baseline

An **infrastructure + measurement** milestone. No engine feature changed. The goal of the project is
100% ECMAScript = the JS language (`test/language/`) **plus** the standard built-in library
(`test/built-ins/`). Up to M36 only `language/` was vendored, measured, and gated. M37 opens up
`built-ins/` — the bulk of the remaining conformance work — by vendoring, measuring, and baselining
it.

## Landed

1. **Vendor `test/built-ins`.** `scripts/vendor-test262.sh test/language test/built-ins` now
   sparse-checks-out both trees at the pinned commit (`test262.pin` =
   `de8e621cdba4f40cff3cf244e6cfb8cb48746b4a`); `harness/` is auto-included. `build.zig`'s
   `zig build vendor` step and the README "Getting started" / Conformance commands were updated to
   vendor BOTH trees. The corpus stays gitignored (≈23,646 built-ins `.js` files; not committed).

2. **Measure.** Measured WITH the harness prelude, per the standard Test262 metric. The full
   `--path built-ins` run cannot complete in one process because `Array` OOMs (see hazard below), so
   the measurement was done per-top-level-subdir with a wall-clock watchdog and aggregated.
   - **Headline: ≈7,690 passed / ≈45,500 mode-runs = ≈16.9%.** (Excludes the 5 OOM `Array`
     partitions, ≈550 files, which contribute ~0 passes — they don't move the headline.)
   - **Failure split:** `unexpected_error` 27,573 (≈82%), `parse_error` 6,010, `step_limit` 40,
     `no_error_expected_throw` 24. The dominant `unexpected_error` is overwhelmingly
     `TypeError: x is not a function` — a missing built-in method — i.e. whole recoverable method
     families.
   - **Top failing top-level objects:** Temporal 9,206 · RegExp 3,372 · TypedArray 2,876 ·
     Object 2,501 · String 1,953 · TypedArrayConstructors 1,446 · Date 1,188 · DataView 1,122 ·
     Iterator 1,014 · Atomics 780 · Set 764 · Promise 666 · Function 663 · Proxy 606 · Math 493 ·
     ArrayBuffer 442 · Map 405 · Number 376 · JSON 330 · Reflect 306. (`Array` ≈5,200 total when its
     OOM partitions are counted as all-fail.)

3. **Baseline + gate.** `baseline/builtins.json` records the **7,744 passing test ids**
   (`<built-ins-relative-path>#<mode>`), built by merging per-subdir `--update-baseline` runs with the
   subdir prefix so each id matches exactly what a full `--path built-ins` run would emit. The OOM
   partitions contribute nothing (a non-passing test is correctly absent), so the baseline is
   conservative and reproducible.

## Realistic stdlib wins vs separate engines

- **Realistic near-term wins** (prototype/static method gaps, pure-JS, high volume):
  `Object` (already 63%), `Array`, `String`, `Iterator` helpers, then `Number`/`Math` long tail.
- **Big separate engines** (large standalone subsystems, NOT quick wins): `Temporal`, `RegExp`,
  `Date`, and the binary/typed-array stack (`TypedArray` + `TypedArrayConstructors` + `DataView` +
  `ArrayBuffer` + `SharedArrayBuffer` + `Atomics` + `Uint8Array`).

## Hazard for the orchestrator — `Array` memory blowup (OOM, NOT an infinite loop)

Running these `Array` partitions balloons RSS to ~5–6 GB and gets OOM-killed (each ~30s, no output
because the runner only prints `total=` at the very end):
`Array/length`, `Array/prototype/indexOf`, `Array/prototype/lastIndexOf`, `Array/prototype/slice`,
and the top-level `Array/*.js` files. Root cause (diagnosed, not fixed — out of scope for this
no-engine-change cycle): tests that set a very large `array.length` (e.g. `2**32-1`) cause the engine
to **eagerly materialize** the backing store. The runner is step-bounded but NOT byte-bounded, and the
engine propagates `error.OutOfMemory` as a Zig error (aborting the run) rather than as a per-test
failure. `ulimit -v` does not help on macOS (Darwin ignores `RLIMIT_AS`). Guard by running `built-ins`
per-top-level-subdir with a per-dir watchdog and excluding these `Array` partitions, OR fix the engine
(lazy/sparse array storage + a per-test memory cap in the runner) in a future cycle.

## Recommended FIRST stdlib cycle

**`Array.prototype` iteration/search method family** — `forEach`/`map`/`filter`/`every`/`some`/
`reduce`/`reduceRight`/`find*`/`indexOf`/`includes`. These are the single biggest cluster of
`TypeError: … is not a function` failures (`every` 417, `filter` 456, `reduce`/`reduceRight` 489
each, `some` 416, `map` 344, `forEach` 297 …), they're clean spec algorithms (no new engine
subsystem), and they share the ArraySpeciesCreate / callback-invocation plumbing so one cycle
recovers thousands of tests. Pair it with the `Array/length` lazy-storage fix to also clear the OOM
hazard. `Object` static/prototype methods (`Object.keys`/`entries`/`assign`/`getOwnPropertyNames`,
already at 63%) are the natural second cycle.
