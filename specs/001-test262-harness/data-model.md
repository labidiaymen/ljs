# Phase 1 Data Model: M0 — Test262 Harness & Minimal Eval

Entities derived from the spec's Key Entities and Requirements. Types are described
conceptually; concrete Zig structs are produced in the implementation phase.

## Engine-core entities

### Value
The minimal JS value for M0. A tagged union over the spec's primitive types in scope.
- **Variants**: `undefined`, `null`, `boolean(bool)`, `number(f64)`, `string([]const u8)`.
- **Notes**: `number` is IEEE-754 double per spec §6.1.6.1. `bigint`, `symbol`, and `object`
  are out of scope for M0 (added in later milestones).

### Completion Record
Models ECMA-262 §6.2.4 completion records — the spine of all evaluation.
- **Fields**: `type` (`normal` | `throw`), `value` (Value). `return`/`break`/`continue` are
  out of scope until control flow exists.
- **Rules**: every evaluation function returns a Completion; abrupt (`throw`) completions
  propagate to the caller (the `?`/ReturnIfAbrupt discipline of Principle III).

### AST Node
Output of the parser; input to the interpreter. M0 expression grammar only.
- **Variants**: `NumberLiteral(f64)`, `StringLiteral([]const u8)`, `BooleanLiteral(bool)`,
  `NullLiteral`, `Unary(op, expr)`, `Binary(op, left, right)`, `ExpressionStatement(expr)`,
  `Program([]Statement)`.
- **Validation**: parser rejects malformed input with a SyntaxError (parse-phase error).

### Realm
An isolated execution environment, constructed fresh per test execution (research D6).
- **Fields**: an arena allocator, a global environment (stub for M0), the run mode.
- **Lifecycle**: created → source evaluated → torn down (arena freed). No state survives across
  realms.

### Evaluation Result
The observable outcome of evaluating a source unit (FR-010).
- **Variants**: `normal(Value)`, `thrown(Value)`, `syntax_error(message)`.
- **Maps to**: the CLI output and the harness's positive/negative classification.

## Harness entities

### Test Case
One Test262 file plus its parsed metadata (FR-002).
- **Fields**: `path`, `source`, `negative` (optional: `type`, `phase`), `includes[]`,
  `flags` (set: `onlyStrict`, `noStrict`, `module`, `raw`, `async`, `generated`, …),
  `features[]`, `description`.
- **Derived**: `applicable_modes` ∈ {strict, sloppy} computed from `flags`.

### Run Mode
- **Values**: `strict`, `sloppy`. Determines whether `"use strict";` is prepended and how the
  source is interpreted.

### Test Result
Outcome of one (Test Case × Run Mode) execution (FR-005, FR-007).
- **Fields**: `path`, `mode`, `outcome` (`pass` | `fail` | `skip`), `reason` (on fail/skip:
  `wrong_error`, `unexpected_error`, `no_error_expected_throw`, `step_limit`, `crash`,
  `unsupported_feature`, `unsupported_flag`, `parse_error`).
- **State transitions**: `applicable?` → if no → `skip(unsupported_*)`; else `execute` →
  classify into `pass` / `fail(reason)`.

### Conformance Report
Aggregate of all Test Results for a run (FR-007, FR-009).
- **Fields**: `total`, `passed`, `failed`, `skipped`, `conformance_pct`
  (= passed / (passed + failed), skips excluded), `results[]` (per Test Result),
  `subset` (path/pattern), `pinned_commit`.
- **Baseline compare**: against a stored baseline of passing test ids → `regressions[]`
  (was-pass-now-fail) and `improvements[]` (was-not-pass-now-pass).

### Baseline
Persisted record of a subset's passing set for regression detection (US3, FR-009).
- **Fields**: `subset`, `pinned_commit`, `passing_ids[]` (path#mode), `conformance_pct`,
  `generated_at` (recorded when written).
- **Stored as**: `baseline/<subset>.json` (see contracts/report-schema.json).

## Relationships

```
Program ──contains──▶ Statement ──contains──▶ Expression (AST Node tree)
TestCase ──(× applicable Run Mode)──▶ executed in a fresh Realm ──▶ Evaluation Result
Evaluation Result ──classified against TestCase.negative──▶ Test Result
Test Result[] ──aggregated──▶ Conformance Report ──compared to──▶ Baseline
```
