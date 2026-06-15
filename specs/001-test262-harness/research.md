# Phase 0 Research: M0 — Test262 Harness & Minimal Eval

All decisions below resolve the Technical Context. No `NEEDS CLARIFICATION` remain.

## D1. Zig toolchain version

- **Decision**: Pin **Zig 0.16.0** (installed via Homebrew). Record `minimum_zig_version =
  "0.16.0"` in `build.zig.zon`.
- **Rationale**: Latest stable; single source of truth for contributors and CI. Constitution
  requires a pinned toolchain.
- **Alternatives considered**: 0.14/0.15 (older, no benefit); `zigup`/`anyzig` multi-version
  managers (overkill for a solo M0 — revisit if CI needs matrix builds).

## D2. Harness: own Zig runner vs. external test262-harness

- **Decision**: Build the runner **in Zig, in-process** (`test262/runner.zig`). The engine is
  invoked directly; each test executes in a freshly constructed realm.
- **Rationale**: No Node.js/JS toolchain dependency; full control over realm construction,
  classification, and reporting; fastest iteration; mirrors the approach of from-scratch
  engines like Kiesel and LibJS. Supports Principles II & III directly.
- **Alternatives considered**: `test262-harness` (Node) and `eshost` — both add an external
  runtime, are slower, and obscure classification logic behind a generic adapter. Rejected.

## D3. Test262 vendoring & pinning

- **Decision**: Vendor the suite via `scripts/vendor-test262.sh`, which clones `tc39/test262`
  at a **specific commit** into `vendor/test262/` and writes the commit hash to
  `vendor/test262/.pinned-commit`. The hash is also referenced in `build.zig.zon`. `vendor/`
  is gitignored (the tree is large).
- **Rationale**: Reproducibility (FR-012, FR-013, SC-006) and no network access at test time.
  The exact commit hash is captured at vendor time and recorded in-repo.
- **Alternatives considered**: git submodule (works, but heavier clones and submodule friction
  for a solo project — kept as a documented fallback); committing the full tree (bloats the
  repo, rejected).

## D4. Conformance target & scope

- **Decision**: Target **ECMA-262 ES2025 (latest)**, implemented **incrementally**. Features
  ljs does not yet support are reported as **skip** (via the test's `features:` metadata and/or
  a parse/eval "unsupported" signal), never as fail.
- **Rationale**: User-selected. Matches how Boa/Kiesel track an ever-rising pass rate against
  the full modern suite rather than freezing an old edition.
- **Alternatives considered**: pin ES2024 (smaller moving target, later bump needed); ES5-first
  (throwaway scoping). Rejected per user decision.

## D5. Metadata (frontmatter) parsing

- **Decision**: Hand-roll a minimal parser in `test262/metadata.zig` for the
  `/*--- ... ---*/` YAML frontmatter, extracting only the keys M0 needs: `negative` (type +
  phase), `includes`, `flags`, `features`, `description`.
- **Rationale**: The frontmatter is a small, regular subset of YAML; the Zig std has no YAML
  parser and pulling a third-party one violates "pure Zig std for M0." Parsing only known keys
  keeps it simple and testable (FR-002, metadata_test.zig).
- **Alternatives considered**: full YAML dependency (rejected — dependency + overkill).

## D6. Realm isolation & memory model

- **Decision**: Each test execution builds a **fresh realm**: a new global environment backed
  by its own arena allocator (`std.heap.ArenaAllocator`), torn down after the run. Strict and
  sloppy executions are separate realms.
- **Rationale**: INTERPRETING.md mandates a fresh realm per test; an arena gives O(1) teardown
  and clean leak isolation between tests (no cross-test state — supports determinism FR-013 and
  fault isolation FR-006).
- **Alternatives considered**: shared realm with manual reset (error-prone, leaks state — the
  classic source of false passes); one OS process per test (clean but slow — deferred, may be
  needed later only for true infinite-loop isolation, see D8).

## D7. Harness helper loading & the M0 baseline reality

- **Decision**: For non-`raw` tests, evaluate `harness/assert.js` and `harness/sta.js`, then
  each file listed in `includes:`, in the test's realm before the test source. `raw` tests run
  the source alone.
- **Rationale**: Required by INTERPRETING.md.
- **Important honest consequence**: those helpers use functions, objects, and `throw` — none of
  which the M0 trivial evaluator supports yet. Therefore **almost no real Test262 test will
  pass at M0, and the full-suite conformance baseline will be ~0%.** This is expected and
  acceptable (spec Assumption: "initial conformance expected to be low"). M0's value is proven
  by *classification accuracy and harness robustness*, not pass rate:
  - SC-001 (classification accuracy) is validated on a hand-curated sample where the harness
    must correctly label pass/fail/skip — including correctly labeling tests it cannot run as
    skip/fail.
  - SC-005 (trivial eval correctness) is validated by **direct unit tests** (`eval_test.zig`),
    not through Test262.
  The pass rate becomes meaningful in M1+ once the evaluator can run the harness helpers.

## D8. Fault isolation & watchdog (no infinite hangs)

- **Decision**: The interpreter carries a **step counter** with a configurable cap; exceeding
  it yields a "step-limit" failure for that test. All engine errors are surfaced as Zig error
  unions / thrown completions that the runner catches per test, so one test never aborts the
  run.
- **Rationale**: Satisfies FR-006 / SC-002 in-process without the cost of per-test subprocesses.
  A step cap is a deterministic substitute for a wall-clock timeout (better for FR-013).
- **Alternatives considered**: wall-clock timeout thread (non-deterministic counts); subprocess
  per test (robust against native crashes/true infinite loops, but slow — deferred to a later
  milestone if/when needed).

## D9. Negative-test phase detection

- **Decision**: Support `negative.phase` values `parse` and `runtime` for M0 (`resolution` is
  module-linking; treated as unsupported → skip until modules exist). A `parse`-phase negative
  passes iff the parser reports the expected error type; a `runtime`-phase negative passes iff
  evaluation throws the expected error type.
- **Rationale**: INTERPRETING.md negative semantics; M0 has no module system.

## D10. Performance benchmarking vs Node (from day one)

- **Decision**: Ship a `bench/` harness at M0 (constitution v1.1.0, Principle IV). Each
  benchmark is a single shared `.js` file in `bench/cases/` run by **both** ljs and Node.js;
  the runner times each engine over N repetitions, reports `ljs_ms`, `node_ms`, and the
  `ratio = ljs_ms / node_ms`, and compares ljs's own times to `bench/baseline.json` to detect
  ljs-vs-self regressions. Reference engine pinned to the locally installed Node (v22.15.1, V8).
- **Measurement method**: wall-clock of whole-process runs (`ljs run case.js` vs
  `node case.js`), warm-up reps discarded, report min/median over the timed reps to reduce
  noise; a configurable noise tolerance (e.g. ±15%) guards the regression check. `hyperfine`
  may be used if installed, but the runner MUST work without it (pure in-harness timing) so the
  gate has no hard external dependency.
- **Gate semantics (per user decision: track + no-regression)**: fail only when ljs is slower
  than its own recorded baseline beyond tolerance; the absolute ratio to Node is reported and
  tracked, never a hard fail (a tree-walker cannot approach V8 at M0).
- **Honest expectation**: at M0 the ljs-vs-Node ratio will be very large (interpreter vs JIT).
  The value is the *trend line* and regression protection, and the data that will later decide
  when to graduate from tree-walk to a bytecode VM.
- **Constraint**: the benchmark cases at M0 must stay within the trivial language subset the
  engine actually supports (arithmetic-heavy expressions, loops once available); cases grow
  with the engine.
- **Alternatives considered**: JS-level microbench libraries (need a capable engine ljs lacks
  at M0 — rejected); benchmarking only ljs without a reference (loses the V8 comparison the
  user asked for — rejected).
- **Implementation (M0):** the runner is `scripts/bench.py` (python3), invoked by
  `zig build bench` the same way `zig build lint` wraps `scripts/lint.sh`. A native
  `bench/runner.zig` was deferred: Zig 0.16's `std.process.Child` subprocess API is
  mid-refactor and not stable to build against yet. The engine itself stays pure Zig; only the
  dev-tooling gate is a script. Revisit a native port when the 0.16 process API settles.

## Summary of resolved unknowns

| Unknown (from Technical Context) | Resolution |
|----------------------------------|-----------|
| Zig version | 0.16.0, pinned (D1) |
| Harness implementation | In-process Zig runner (D2) |
| Test262 acquisition/pinning | Vendor script + pinned commit (D3) |
| Spec edition / scope | ES2025, incremental, unsupported → skip (D4) |
| Metadata parsing | Minimal hand-rolled frontmatter parser (D5) |
| Realm isolation | Fresh arena-backed realm per execution (D6) |
| Helper loading + baseline expectation | Load helpers; baseline ~0% at M0 by design (D7) |
| Timeout/crash handling | Step-cap watchdog + per-test error catching (D8) |
| Negative phases | parse + runtime; resolution → skip (D9) |
| Performance benchmarking | `bench/` harness, ljs vs Node from day one, track + no-regression (D10) |
