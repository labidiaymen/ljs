---
description: "Task list for M17 — iterator-correct destructuring + step-bounded iterator loops"
---

# Tasks: M17 — Iterator-correct destructuring

## Cycle 1 (DONE — conformance 61.0% → 63.1%, +920, 0 regressions)
- [x] M17-T010 §8.5.2/§13.15.5.3 array-pattern destructuring (`bindPattern` + `assignPattern`):
  step the iterator once per element, rest-only drain, IteratorClose (§7.4.11) when the fixed
  pattern is satisfied and the iterator is not done, close-on-abrupt. Fixes the
  `meth-ary-init-iter-close.js` hang (infinite iterator) and the `class/dstr` / `assignment/dstr`
  iterator-close + step-count tests.
- [x] M17-T011 Reliability: `try self.tick()` in every native iterator-drain loop (`iterateToList`/
  spread, `for-of`, `for await`, rest drain, `yield*`) so an unbounded iterator fails with
  `StepLimitExceeded` instead of hanging the runner.
- [x] M17-T012 Tests (engine.zig) + re-measure: 63.1%, bench green.

## Notes
- Root cause was found by isolating the conformance hang to `expressions/class/dstr` →
  `meth-ary-init-iter-close.js` (a 99%-CPU native loop the step-limit didn't bound).
- The runner's per-test arena fix (commit `6e44850`) keeps memory bounded; with the hang gone the
  full `language/` run completes in well under a minute.
