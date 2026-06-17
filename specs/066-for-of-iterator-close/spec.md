# Feature Specification: for-of IteratorClose error propagation (§7.4.11)

**Feature Branch**: `066-for-of-iterator-close` (milestone **M78**)
**Created**: 2026-06-17
**Status**: Done — language 89.4% (39056, +8 vs M77, 0 regressions)

**Input**: §7.4.11 IteratorClose. When a `for-of` loop exits a still-open iterator on a NORMAL
completion (`break`, a loop-exiting labelled `continue`, or `return`), it must call `return()` and
PROPAGATE any error that method throws (and throw a TypeError if `return()` yields a non-object).
ljs's `iteratorClose` swallows ALL `return()` results, so `for (x of it){ break; }` where
`it.return()` throws is silently ignored (VERIFIED: not caught). When the loop exits on a THROW
completion, the original error wins and the `return()` error IS swallowed (§7.4.11 step 4) — ljs is
already correct there.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — return() error propagates on normal exit (Priority: P1)
1. **Given** an iterator whose `return()` throws, **When** `for (var x of it){ break; }`, **Then**
   the thrown error propagates (a surrounding try/catch catches it).
2. **Given** the same, **When** the loop body does `return` (inside a function), **Then** the
   return()-error propagates.
3. **Given** an iterator whose `return()` yields a non-object, **When** the loop `break`s, **Then**
   a TypeError is thrown.

### Regression guards
1. THROW exit: `for (x of it){ throw new Error("body"); }` where `it.return()` ALSO throws →
   the BODY error wins (return()-error swallowed), per §7.4.11 step 4.
2. Clean `return()` (returns an object): `break` exits the loop normally, no throw.
3. `for (x of [1,2,3]){ break; }` (array fast iterator, no `return`) — unaffected.

## Requirements
- **FR-001**: A new `iteratorCloseChecked` performs §7.4.11 for a non-throw incoming completion:
  GetMethod("return"); undefined/null → no-op; non-callable → TypeError; call it; a thrown error
  propagates; a non-object result → TypeError. The existing void `iteratorClose` (swallow) remains
  for THROW-completion closes. evalForOf uses the checked variant at break / loop-exiting-continue /
  return sites and keeps the swallowing variant at the abrupt-binding and throw sites.

## Success Criteria
- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.  • **SC-002**: bench ok.
