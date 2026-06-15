---
description: "Task list for M0 — Test262 harness & minimal eval"
---

# Tasks: M0 — Test262 Conformance Harness & Minimal Evaluation Pipeline

**Input**: Design documents from `specs/001-test262-harness/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED. This project is test-gated by constitution (Principle II: conformance is
the acceptance gate; Principle V: ships with the tests that prove it). Test tasks are written
before the implementation they verify.

**Organization**: by user story. Note the real dependency (research D7): both US1 and US2 run
on a shared engine core, so that core lives in Foundational (Phase 2). **MVP = Setup +
Foundational + US1 + US4** (you can measure both conformance *and* ljs-vs-Node performance).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1 / US2 / US3 (Setup, Foundational, Polish carry no story label)
- Paths are repo-root-relative (`~/ljs`).

---

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Create `build.zig.zon` at repo root (name `ljs`, `minimum_zig_version = "0.16.0"`, a `test262_commit` field for the pinned hash)
- [ ] T002 Create `build.zig` at repo root wiring the `ljs` exe and the `run`, `test`, and `test262` steps
- [ ] T003 [P] Create the source skeleton (empty/stub files): `src/`, `test262/`, `tests/`, `scripts/`, `baseline/`
- [ ] T004 [P] Create `scripts/vendor-test262.sh` (clone tc39/test262 at the pinned commit into `vendor/test262/`, write `vendor/test262/.pinned-commit`)
- [ ] T005 [P] Confirm `.gitignore` covers `vendor/test262/`, `.zig-cache/`, `zig-out/` (already present — verify)
- [x] T005b [P] Add code-quality gate: `zig build fmt` / `fmt-check` (`zig fmt`) + `zig build lint` (`scripts/lint.sh`: fmt-check + `zlint --deny-warnings`) — constitution merge gate 1. ZLint v0.8.1 installed from the prebuilt release (its source build fails under Zig 0.16); lint.sh skips it gracefully if absent.

---

## Phase 2: Foundational (Blocking Prerequisites — the engine core)

**⚠️ CRITICAL**: Both user stories depend on this. No story work begins until this is done.

- [ ] T006 Implement `Value` in `src/value.zig` (undefined/null/boolean/number/string + spec string form), cite ECMA-262 §6.1
- [ ] T007 Implement `Completion` record in `src/completion.zig` (normal/throw + ReturnIfAbrupt helper), cite §6.2.4
- [ ] T008 [P] Define AST nodes in `src/ast.zig` (number/string/boolean/null literals, unary, binary, expression statement, program)
- [ ] T009 Implement the lexer in `src/lexer.zig` (numbers, strings, `true`/`false`/`null`, `+ - * / %`, `!`, parens, `;`)
- [ ] T010 Implement the Pratt parser in `src/parser.zig` → AST; report SyntaxError on malformed input (depends T008, T009)
- [ ] T011 Implement the realm stub in `src/realm.zig` (arena-backed global env + run mode), cite the fresh-realm rule
- [ ] T012 Implement the tree-walk interpreter in `src/interpreter.zig` (AST → Completion) with a step-cap watchdog and inline spec-clause comments (ToNumber §7.1.4, Addition §13.15, …) (depends T006, T007, T008, T011)
- [ ] T013 Implement the engine entry point `evaluate(allocator, source, mode) -> EvaluationResult` in `src/engine.zig`, wiring lexer → parser → interpreter (depends T009, T010, T012)

**Checkpoint**: the engine can turn a source string into a normal/thrown/syntax-error result.

---

## Phase 3: User Story 1 — Measure conformance against Test262 (P1) 🎯 MVP

**Goal**: point ljs at a Test262 subset and get an accurate, reproducible pass/fail/skip report.

**Independent Test**: run the harness on the curated sample; classification matches manual labels (SC-001).

### Tests for User Story 1 (write first, must fail)

- [x] T014 [P] [US1] 20 curated fixtures in `tests/fixtures/sample/` (positive, negative-parse pass/fail, negative-runtime, onlyStrict/noStrict/raw, module/async skip)
- [x] T015 [P] [US1] Metadata frontmatter tests (inline in `test262/metadata.zig`) — FR-002
- [x] T016 [P] [US1] Classification tests (inline in `test262/runner.zig`) + end-to-end on fixtures = **27/6/2 (81.8%)**, matches hand-tally — SC-001

### Implementation for User Story 1

- [x] T017 [US1] Frontmatter parser `test262/metadata.zig` (negative type/phase, includes, flags, features, description)
- [x] T018 [US1] Discovery + applicable-mode in `test262/runner.zig` (recursive `Io.Dir.Walker`, skip `_FIXTURE`/`harness/`) — FR-001, FR-003
- [~] T019 [US1] Per-test execution: fresh realm per eval, strict+sloppy, strict prologue. **Harness-include loading (sta.js/assert.js) DEFERRED** — the trivial evaluator can't run them yet (research D7); `--harness-dir` reserved.
- [x] T020 [US1] Classification (positive; negative parse|runtime; skip module/async) + fault isolation (engine surfaces parse/runtime/step-limit as result variants, never crashes) — FR-005, FR-006
- [x] T021 [US1] Report aggregation (counts, conformance %) + summary/detail in `test262/report.zig` — FR-007
- [x] T022 [US1] Wired `zig build test262 -- --path/--mode/--harness-dir/--step-limit` — FR-008
- [x] T022b [US1] Engine: added §12.4 comment support to the lexer (line + block) — required so Test262 frontmatter parses; `ljs eval/run` now skip comments too

**Checkpoint**: MVP — conformance is measurable and reproducible on a subset.

---

## Phase 3B: User Story 4 — Benchmark ljs vs Node from day one (P1, co-MVP)

**Goal**: from the first runnable build, report ljs time / Node time / ratio per benchmark and
catch ljs-vs-self perf regressions (constitution v1.1.0, Principle IV).

**Independent Test**: run `zig build bench`; a report with ljs/Node/ratio appears, and a
deliberately slowed case is flagged as a regression (SC-007, SC-008).

> Co-P1 with US1. T035 lands during Setup/Foundational (skeleton runnable as soon as `ljs run`
> exists); the rest follows once the engine entry point (T013) and `ljs run` (T024) exist.

- [x] T035 [P] [US4] Benchmark cases `bench/cases/*.js` (arith_sum, arith_mix, string_cat) + runner — implemented as `scripts/bench.py` (note ↓), not `bench/runner.zig`
- [x] T036 [US4] Timing in `scripts/bench.py`: run each case on ljs (`ljs run`) and Node, warm-up + N reps, report `ljs_ms`/`node_ms`/`ratio` (min+median) — FR-014
- [x] T037 [US4] Node-absent handling: still time ljs, mark Node column `n/a`, don't fail — FR-016, SC-009
- [x] T038 [US4] ljs baseline read/write (`bench/baseline.json`) + ljs-vs-self regression detection with ±tolerance + `--update-baseline` — FR-015, SC-008
- [x] T039 [US4] Wired `zig build bench -- [--update-baseline] [--reps N]` in `build.zig` (runs `scripts/bench.py`, builds ljs first) — verified: ratios reported + regression detected (exit 1)

> **Design note (autonomous call):** the M0 bench runner is `scripts/bench.py` (mirrors `scripts/lint.sh`), not a native `bench/runner.zig`. Zig 0.16's subprocess API (`std.process.Child`) is mid-refactor and not stable to build against now; the engine stays pure Zig and a native runner is deferred until that API settles. See research.md D10.

**Checkpoint**: the ljs-vs-Node performance signal exists and is regression-protected.

---

## Phase 4: User Story 2 — Evaluate a minimal program end-to-end (P2)

**Goal**: `ljs eval "<src>"` / `ljs run <file>` returns spec-correct observable results.

**Independent Test**: each trivial case yields the spec-correct value (SC-005).

### Tests for User Story 2 (write first, must fail)

- [ ] T023 [P] [US2] Write `tests/eval_test.zig` with ≥20 trivial cases (literals, unary `+ - !`, binary `+ - * / %`, grouping, comparison, string concat) — SC-005

### Implementation for User Story 2

- [ ] T024 [US2] Implement `ljs eval "<src>"` and `ljs run <file>` in `src/main.zig` (value string form to stdout; `Uncaught …`/`SyntaxError …` to stderr; exit codes per `contracts/cli.md`) — FR-010 (depends T013)
- [ ] T025 [US2] Verify/extend the interpreter so all trivial-set cases are spec-correct → makes T023 pass — FR-011 (depends T012)

**Checkpoint**: US1 + US2 both work independently.

---

## Phase 5: User Story 3 — Detect conformance regressions (P3)

**Goal**: record a baseline; flag any later run where a previously passing test fails.

**Independent Test**: baseline → inject regression → detected (SC-004).

### Tests for User Story 3 (write first, must fail)

- [x] T026 [P] [US3] Faulty fixture `tests/fixtures/faulty/steplimit.js` + threaded the interpreter step-cap (`evaluateWithLimit`, `--step-limit`). Verified: tight limit → 2 step_limit fails, run completes, no hang (SC-002)
- [x] T027 [P] [US3] Regression-detection test (inline in `test262/report.zig`) — record → regress → detect (SC-004)

### Implementation for User Story 3

- [x] T028 [US3] Baseline read/write in `test262/report.zig` (`baselineBytes` emits a JSON id array; `parseIds` reads it) via `Io.Dir` writeFile/readFileAlloc — M0 subset of report-schema.json
- [x] T029 [US3] `regressionsVs` (passing-id diff) + `--baseline`/`--update-baseline` flags + exit codes 0/1/2 in `test262/main.zig` — FR-009. Verified: clean run ok; injected regression → exit 1

**Checkpoint**: all three stories independently functional.

---

## Phase 6: Polish & Cross-Cutting

- [ ] T030 [P] Audit inline spec-clause comments across `src/` (Principle III)
- [ ] T031 [P] Add `std.testing.allocator` leak checks to every test; ensure zero leaks (constitution gate)
- [ ] T032 Run `quickstart.md` §2–§6 end-to-end; record the baseline conformance % for the curated subset (SC-006)
- [x] T033 [P] Write `README.md` (build, run, test, lint, roadmap, layout)
- [ ] T034 Determinism check: run the harness twice, `diff` the JSON reports (SC-003)
- [ ] T040 Record the initial ljs-vs-Node benchmark ratios in the milestone report and set `bench/baseline.json` (SC-007); confirm the perf gate is wired into the workflow

---

## Dependencies & Execution Order

- **Setup (P1)** → **Foundational (P2, the engine core)** → **US1 / US2 / US3**.
- US1 execution (T019) depends on the engine entry point (T013). US2 (T024–T025) depends on
  T012/T013. US3 (T028–T029) depends on US1's report layer (T021).
- Within a story: write the failing test first, then implement to green.

### Parallel opportunities

- Setup: T003, T004, T005 in parallel.
- Foundational: T008 parallel with T006/T007; T009 before T010.
- US1 tests T014/T015/T016 in parallel before implementation.
- Across stories after Foundational: US2 and US3-tests can proceed alongside US1 (different files).

## Implementation Strategy

1. **MVP** = Phase 1 + Phase 2 + Phase 3 (US1) + Phase 3B (US4): conformance is measurable AND
   ljs-vs-Node performance is measured/regression-protected from the start. **STOP & VALIDATE**
   against the curated sample (SC-001), the fault/determinism checks, and the benchmark report
   (SC-007/008).
2. Add US2 (`ljs eval`) → validate SC-005.
3. Add US3 (baseline/regression) → validate SC-004/SC-006.
4. Polish.

> Cross-cutting cadence (Principle IV): once `ljs run` exists, run `zig build bench` on every
> increment so the ljs-vs-Node ratio and the no-regression gate are checked continuously — not
> just at Polish.

## Notes

- Expected at M0: real-suite pass rate ≈ 0% **by design** (research D7). M0 is validated by
  classification accuracy, fault isolation, determinism, regression detection, and the trivial
  eval unit set — not by pass rate.
- Commit after each task or logical group, following `CLAUDE.md` (no Claude attribution/author).
