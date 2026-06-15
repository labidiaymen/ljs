# Feature Specification: M0 — Test262 Conformance Harness & Minimal Evaluation Pipeline

**Feature Branch**: `001-test262-harness`

**Created**: 2026-06-15

**Status**: Draft

**Input**: User description: "M0: Test262 conformance harness plus minimal evaluation pipeline"

## User Scenarios & Testing *(mandatory)*

> Note: the "users" of this milestone are the ljs engine developers and the project's CI.
> M0 builds the measuring stick (conformance harness) before the thing it measures, per the
> project constitution (Principle II: Conformance Is the Acceptance Gate; Principle V:
> harness built before features).

### User Story 1 - Measure conformance against Test262 (Priority: P1)

As an engine developer, I can point ljs at a chosen slice of the official ECMAScript
conformance suite (Test262) and get back an accurate, reproducible report of how many tests
pass, fail, or are skipped, plus a conformance percentage.

**Why this priority**: This is the MVP and the foundation of the whole project. Without an
objective, externally-owned pass/fail signal, no later milestone can claim it is "done."
Everything else is gated on this existing.

**Independent Test**: Run the harness against a hand-picked set of ~20 Test262 files whose
correct outcomes have been classified by hand; confirm the harness's pass/fail/skip
classification matches the manual classification exactly.

**Acceptance Scenarios**:

1. **Given** a vendored Test262 suite at a pinned commit, **When** the developer runs the
   harness over a directory subset, **Then** it produces a summary (total / passed / failed /
   skipped / conformance %) and a per-test result list.
2. **Given** a test whose metadata marks it as a negative test (expected to throw a specific
   error at a specific phase), **When** the engine produces that exact error at that phase,
   **Then** the harness records the test as **passed**.
3. **Given** a test that requires harness helper files or `includes`, **When** the test is
   executed, **Then** those helpers are loaded first and the test runs against them.
4. **Given** a test flagged for only one mode (e.g. `onlyStrict`, `noStrict`, `raw`,
   `module`), **When** the harness runs it, **Then** it runs it only in the permitted
   mode(s); otherwise it runs the test in **both** strict and sloppy mode.
5. **Given** a test that exercises a language feature ljs does not yet support, **When** it is
   run, **Then** it is recorded as **skipped** (not failed).

### User Story 2 - Evaluate a minimal program end-to-end (Priority: P2)

As an engine developer, I can hand ljs a small piece of JavaScript source and get back its
observable result — a normal completion value or a thrown error — proving the
source-to-result pipeline exists end-to-end.

**Why this priority**: A working (if tiny) evaluation path is what the harness actually
exercises. It is the smoke test that turns the harness from "runs and reports 0%" into
"runs and reports a real, non-zero baseline."

**Independent Test**: Evaluate each expression in a defined trivial set (literals,
arithmetic, basic comparisons) and confirm each yields the spec-correct observable result.

**Acceptance Scenarios**:

1. **Given** a trivial arithmetic source (e.g. `1 + 2`), **When** evaluated, **Then** the
   observable result is the spec-correct value (`3`).
2. **Given** a source that throws (e.g. a thrown value), **When** evaluated, **Then** the
   thrown value is reported as a thrown completion, not a host crash.
3. **Given** a syntactically invalid source, **When** evaluated, **Then** a syntax error is
   reported as the result, not a host crash.

### User Story 3 - Detect conformance regressions over time (Priority: P3)

As an engine developer, I can record a conformance baseline for a subset and have the harness
flag any later run in which a previously passing test now fails.

**Why this priority**: The constitution requires the pass count to be monotonic
non-decreasing. Automating regression detection makes that gate enforceable rather than
aspirational. It builds directly on US1 and is valuable but not required for the first
measurement.

**Independent Test**: Record a baseline, deliberately break the engine so one passing test
now fails, re-run, and confirm the regression is surfaced (flagged in the report and/or
non-zero exit status).

**Acceptance Scenarios**:

1. **Given** a recorded baseline, **When** a run has the same or more passing tests, **Then**
   the harness reports success.
2. **Given** a recorded baseline, **When** a previously passing test now fails, **Then** the
   harness identifies the specific regressed test(s) and signals failure.

### User Story 4 - Benchmark ljs against Node from day one (Priority: P1)

As an engine developer, from the very first runnable build I can run a shared benchmark set on
both ljs and Node.js and get a side-by-side report (ljs time, Node time, ljs-vs-Node ratio),
with ljs's own results compared to its previous baseline so any performance regression is
caught immediately.

**Why this priority**: Per constitution Principle IV, performance is measured from day one, not
retrofitted. Establishing the ljs-vs-Node measurement at M0 means every later change is made
with the performance gap visible and under control, and lets benchmark data — not guesswork —
decide when to graduate execution tiers. It is co-equal P1 with US1: conformance and
performance are the two signals the project steers by.

**Independent Test**: Run the benchmark set against both engines; confirm a report is produced
with per-benchmark ljs time, Node time, and the ratio, and that re-running ljs flags a
deliberately slowed benchmark as a regression.

**Acceptance Scenarios**:

1. **Given** a shared benchmark set and both engines available, **When** the benchmark runs,
   **Then** it reports for each benchmark: ljs time, Node time, and the ljs-vs-Node ratio.
2. **Given** a recorded ljs performance baseline, **When** ljs runs the same benchmarks within
   tolerance of the baseline, **Then** the perf gate passes.
3. **Given** a recorded ljs performance baseline, **When** ljs is meaningfully slower than its
   baseline on a benchmark (beyond noise tolerance), **Then** the run flags a performance
   regression.
4. **Given** Node.js is not installed, **When** the benchmark runs, **Then** ljs is still
   benchmarked and the Node column is reported as unavailable (the run does not fail).

### Edge Cases

- A test crashes, hangs, or exhausts resources → it is recorded as **failed** (with reason)
  and the run continues; one bad test never aborts the whole run.
- A test exceeds a per-test time budget → recorded as a failure/timeout, run continues.
- A `_FIXTURE` / non-test support file is encountered during discovery → it is excluded from
  the test count.
- The vendored Test262 directory is missing or at an unexpected commit → the harness reports
  a clear setup error rather than silently reporting 0 tests.
- A test's metadata cannot be parsed → recorded as a harness error for that file, run
  continues.
- A negative test produces an error of the wrong type or at the wrong phase → recorded as
  **failed**, not passed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The harness MUST discover Test262 test files recursively under a configured
  path, excluding support/fixture files that are not themselves tests.
- **FR-002**: The harness MUST parse each test's metadata (at minimum: `negative` type and
  phase, `includes`, `flags`, `features`, and description).
- **FR-003**: The harness MUST execute each applicable test in **both** strict and sloppy
  mode, except where flags restrict the mode (`onlyStrict`, `noStrict`, `raw`, `module`),
  and MUST run each execution in a **fresh, isolated** execution environment (realm).
- **FR-004**: The harness MUST load the required harness helper files and any declared
  `includes` before executing a test, except for tests flagged `raw`.
- **FR-005**: The harness MUST classify each run per the suite's interpretation rules: a
  positive test passes if it completes with no uncaught error; a negative test passes only if
  the expected error type occurs at the expected phase (parse vs runtime); unsupported
  features or flags result in **skip**.
- **FR-006**: The harness MUST isolate failures — an exception, crash, or timeout in one test
  MUST be recorded and MUST NOT abort the overall run.
- **FR-007**: The harness MUST produce a summary report containing total, passed, failed, and
  skipped counts and a conformance percentage, plus a per-test outcome list including the mode
  and failure reason where applicable.
- **FR-008**: The harness MUST support restricting a run to a subset (by path or pattern) so a
  milestone can target specific areas of the suite.
- **FR-009**: The harness MUST support recording a conformance baseline and detecting
  regressions against it (previously passing tests that now fail), signalling regressions
  distinctly from a clean run.
- **FR-010**: The engine MUST provide an entry point that accepts JavaScript source and reports
  the observable outcome of evaluating it as either a normal completion value or a thrown
  completion.
- **FR-011**: The minimal evaluation pipeline MUST produce spec-correct observable results for
  a defined trivial set of inputs (numeric and string literals, basic arithmetic, basic
  comparison).
- **FR-012**: The Test262 suite version and the target ECMA-262 edition MUST be pinned at a
  recorded commit/version, consistent with the constitution.
- **FR-013**: Conformance runs MUST be reproducible — running the same subset against the same
  engine build twice MUST yield identical pass/fail/skip counts.
- **FR-014**: The project MUST provide a shared benchmark set runnable on both ljs and Node.js,
  reporting per benchmark: ljs time, Node time, and the ljs-vs-Node ratio (US4). The benchmark
  runner MUST work from the first runnable build of the engine.
- **FR-015**: The benchmark runner MUST record an ljs performance baseline and detect
  regressions of ljs against its own previous baseline (beyond a configurable noise tolerance),
  signalling a regression distinctly. The absolute gap to Node is reported but is NOT a hard
  failure (per constitution Principle IV: track + no-regression).
- **FR-016**: If Node.js is unavailable, the benchmark runner MUST still measure ljs and report
  the Node column as unavailable, without failing the run.

### Key Entities

- **Test Case**: one Test262 file plus its parsed metadata (negative type/phase, includes,
  flags, features, description).
- **Run Mode**: strict or sloppy; determines how a test's source is interpreted.
- **Test Result**: the outcome of one execution — pass / fail / skip — with the mode, and a
  reason on failure (wrong/no error, crash, timeout, unsupported).
- **Conformance Report**: aggregate counts, conformance percentage, per-test results, and
  comparison against a recorded baseline.
- **Realm**: an isolated execution environment created fresh for each test execution.
- **Evaluation Result**: the completion (normal value or thrown value, or a syntax error) from
  evaluating a source unit.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a hand-classified sample of at least 20 Test262 files (mix of positive,
  negative, strict-only, and includes-using tests), the harness's pass/fail/skip
  classification matches the manual classification with 100% accuracy.
- **SC-002**: A deliberately crashing or hanging test does not stop the run — the run
  completes and reports that test as failed/timeout — in 100% of injected-fault trials.
- **SC-003**: Running the same subset against the same build twice produces identical
  pass/fail/skip counts (deterministic).
- **SC-004**: An injected regression (a previously passing test made to fail) is detected and
  surfaced in 100% of trials.
- **SC-005**: The minimal evaluation pipeline returns the spec-correct result for 100% of a
  defined trivial input set of at least 20 cases.
- **SC-006**: A baseline conformance percentage for the targeted subset is recorded and can be
  reproduced from a clean checkout.
- **SC-007**: From the first runnable build, a benchmark report exists giving, for each
  benchmark, ljs time, Node time, and the ljs-vs-Node ratio (US4).
- **SC-008**: An injected ljs performance regression (a benchmark made meaningfully slower than
  the recorded ljs baseline) is detected and surfaced in 100% of trials.
- **SC-009**: The benchmark run completes and still reports ljs timings when Node.js is absent
  (Node column marked unavailable), in 100% of trials.

## Assumptions

- The "users" of this milestone are ljs engine developers and CI, not end users of a product.
- Test262 is vendored locally at a pinned commit; the exact commit and the target ECMA-262
  edition are chosen during planning (`/speckit-plan`), not in this spec.
- Initial conformance is expected to be **low**; M0's goal is to establish an accurate,
  reproducible measurement baseline — not to hit a particular pass rate.
- The minimal evaluation pipeline intentionally covers only a trivial subset of the language,
  sufficient to validate the end-to-end pipeline and produce a non-zero baseline; broader
  language coverage is the subject of later milestones.
- No network access is required at test time; the suite is available locally.
- In scope for M0 (per constitution v1.1.0, Principle IV): **performance measurement** — a
  shared ljs-vs-Node benchmark set, a recorded ljs baseline, and ljs-vs-self regression
  detection — runnable from the first build.
- Out of scope for M0: performance *optimization* work and any bytecode or JIT tier (these are
  graduated later, gated by the benchmark data this milestone starts collecting); the full
  built-in library; and full module-system support beyond what is needed to classify and run
  the targeted subset. Note: ljs will be far slower than Node at M0 — that gap is *measured and
  tracked*, not closed, in this milestone.

## Dependencies

- The official ECMAScript Conformance Test Suite (Test262) and its interpretation rules.
- The ECMA-262 specification as the normative definition of correct observable behavior.
- Node.js (V8) as the performance reference engine for the benchmark set (US4). Optional at
  run time: if absent, ljs is still benchmarked (FR-016).
