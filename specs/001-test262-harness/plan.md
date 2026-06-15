# Implementation Plan: M0 — Test262 Conformance Harness & Minimal Evaluation Pipeline

**Branch**: `001-test262-harness` | **Date**: 2026-06-15 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-test262-harness/spec.md`

## Summary

Build the measuring apparatus before the engine: a Zig-native Test262 runner that discovers
tests, parses their metadata, executes each in a fresh realm in strict + sloppy mode, and
classifies pass/fail/skip per INTERPRETING.md — plus a minimal tree-walk evaluation pipeline
(lexer → parser → tree-walk interpreter) sufficient to evaluate trivial expressions
end-to-end and produce a real, reproducible conformance baseline with regression detection.

Approach: a single Zig project, pure standard library, no third-party code dependencies for
M0. The Test262 suite is vendored at a pinned commit. Correctness-first, tree-walk only — no
bytecode, no JIT, no performance work (constitution Principle IV).

## Technical Context

**Language/Version**: Zig 0.16.0 (pinned; recorded as `minimum_zig_version` in `build.zig.zon`)

**Primary Dependencies**: None (Zig `std` only). Test262 is vendored test *data*, not a code
dependency. No Node.js / external harness.

**Storage**: Filesystem — vendored Test262 tree (read-only) and a JSON conformance baseline
file per subset.

**Testing**: `zig build test` (Zig's built-in test runner) for unit tests; `zig build test262`
runs the conformance harness as an integration runner.

**Target Platform**: Native executable. Dev: macOS/arm64 (Darwin 25). CI: Linux x86_64.

**Project Type**: Language engine / compiler — single project.

**Performance Goals**: Optimization is not an M0 goal, but **measurement is** (Principle IV).
M0 ships a shared ljs-vs-Node benchmark set, records an ljs baseline, and gates against
ljs-vs-self regressions. Reference engine: Node.js v22.15.1 (V8). Expect ljs (tree-walk) to be
orders of magnitude slower than Node at M0 — that ratio is reported and tracked, not a hard
fail. Soft target: the curated conformance subset runs in under a minute on a dev machine.

**Constraints**: No undefined behavior; no memory leaks in the harness or tests (verified via
`std.testing.allocator` / `GeneralPurposeAllocator` leak detection); fully deterministic runs
(FR-013).

**Scale/Scope**: Test262 is 50k+ files; M0 targets (a) a hand-curated classification sample of
≥20 files and (b) a trivial evaluation set of ≥20 expressions. A full-suite run is supported
but expected to report a near-zero pass rate at M0 (see research.md) — that is by design.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | How this plan complies | Verdict |
|---|-----------|------------------------|---------|
| I | Spec is source of truth | Classification follows INTERPRETING.md; the minimal evaluator cites ECMA-262 clauses inline (e.g. `12.8.3 ToNumber`, `13.15 Addition`). | ✅ PASS |
| II | Conformance is the gate | This milestone *is* the conformance gate: harness + baseline + regression detection (US3, FR-009). | ✅ PASS |
| III | Spec traceability in code | `src/` mirrors spec shape (Value, Completion Record, evaluation by production); spec-clause comments required by the quality gate. | ✅ PASS |
| IV | Performance measured from day one | Ships a shared ljs-vs-Node benchmark set + recorded ljs baseline + ljs-vs-self no-regression gate (US4), runnable from the first build. Tree-walk only; tier graduation deferred until benchmark data justifies it. | ✅ PASS |
| V | Incremental, milestone-gated | M0 builds the harness *before* the features it measures; ships with its own unit tests. | ✅ PASS |

**Result**: No violations. Complexity Tracking section intentionally empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-test262-harness/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (CLI + report schema)
│   ├── cli.md
│   └── report-schema.json
└── checklists/
    └── requirements.md  # from /speckit-specify
```

### Source Code (repository root)

```text
build.zig                # build graph: exe `ljs`, `zig build test`, `zig build test262`, `zig build bench`
build.zig.zon            # package manifest; minimum_zig_version = 0.16.0; pinned test262 commit

src/                     # the engine core (tree-walk, trivial subset for M0)
├── main.zig             # CLI entry: `ljs eval "<src>"`, `ljs run <file>`
├── value.zig            # JS Value (undefined, null, boolean, number, string)
├── completion.zig       # Completion Record (normal | throw), abrupt helpers
├── lexer.zig            # minimal lexer (numbers, strings, + - * / %, parens, ;)
├── ast.zig              # AST node definitions (expressions, expression statement)
├── parser.zig           # Pratt parser → AST
├── interpreter.zig      # tree-walk evaluator + step cap (watchdog)
└── realm.zig            # minimal realm / global environment stub

test262/                 # the conformance harness (separate from engine core)
├── runner.zig           # discover → parse → execute (strict+sloppy, fresh realm) → classify
├── metadata.zig         # frontmatter (/*--- ... ---*/) parser: negative/includes/flags/features
└── report.zig           # report aggregation + JSON baseline compare / regression detection

bench/                   # performance: ljs vs Node, from day one (US4)
├── runner.zig           # runs each benchmark on ljs + node, times both, computes ratio
├── cases/               # shared benchmark sources (same .js run by both engines)
│   └── *.js
└── baseline.json        # recorded ljs timings for ljs-vs-self regression detection

tests/                   # unit tests (zig build test)
├── eval_test.zig        # SC-005: trivial expression set → spec-correct values
├── metadata_test.zig    # FR-002: frontmatter parsing
└── classify_test.zig    # SC-001: classification on the hand-curated sample

scripts/
└── vendor-test262.sh    # clone Test262 at the pinned commit into vendor/ (records the hash)

baseline/                # recorded conformance baselines per subset (US3)
└── <subset>.json

vendor/test262/          # vendored suite at pinned commit (gitignored; fetched by script)
```

**Structure Decision**: Single Zig project. The engine core lives in `src/`; the conformance
harness lives in `test262/` and is wired as its own build step (`zig build test262`) so the
measuring apparatus is cleanly separable from the engine it measures (Principle V). The harness
runs the engine **in-process**, constructing a fresh realm per execution.

## Complexity Tracking

> No constitution violations — nothing to justify. (Section intentionally empty.)
