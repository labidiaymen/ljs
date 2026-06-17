# Feature Specification: array-destructuring IteratorClose error propagation (§7.4.11)

**Feature Branch**: `067-destructuring-iterator-close` (milestone **M79**)
**Created**: 2026-06-17
**Status**: Done — language 89.4%->89.6% (39108, +52 vs M78, 0 regressions)

**Input**: §8.5.2 / §13.15.5.3 + §7.4.11. After an array BindingPattern (`var [a] = it`) or
AssignmentPattern (`[a] = it`) is satisfied WITHOUT a rest element and the iterator is not done,
IteratorClose runs on a NORMAL completion — so a throwing `return()` (or a non-object `return()`
result) must PROPAGATE. ljs's `destrClose` swallows all `return()` results. (The abrupt-completion
closes — a throwing default / sub-pattern / element target mid-destructuring — correctly keep the
original error, §7.4.11 step 4.) Companion to M78 (which fixed the for-of close); reuses
`iteratorCloseChecked`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — return() error propagates after normal destructuring (Priority: P1)
1. **Given** an iterator whose `return()` throws, **When** `var [a] = it` binds `a` (iterator not
   exhausted), **Then** the thrown error propagates.
2. **Given** the same, **When** `[a] = it` (assignment), **Then** it propagates.
3. **Given** an iterator whose `return()` yields a non-object, **When** `var [a] = it`, **Then** a
   TypeError is thrown.

### Regression guards
1. Abrupt element: `var [a = (()=>{throw 1})()] = it` where `it.return()` ALSO throws → the DEFAULT
   error wins (return()-error swallowed).
2. `var [a, ...rest] = it` (rest drains the iterator → no close) — unaffected.
3. `var [a] = [1, 2]` (plain-array fast path, no iterator object) — no throw, `a === 1`.
4. A clean `return()` (yields an object) — binding succeeds, no throw.

## Requirements
- **FR-001**: A new `destrCloseChecked(rec)` performs §7.4.11 for a NORMAL completion: for a real
  not-done iterator it delegates to `iteratorCloseChecked` (propagate throw / non-object TypeError);
  fast-path / done → no-op. Used at the two "pattern satisfied, no rest" sites in `bindPattern`
  (array) and `assignPattern` (array). The abrupt-completion `destrClose` sites keep swallowing.

## Success Criteria
- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.  • **SC-002**: bench ok.
