# Plan: for-of IteratorClose error propagation (M78 / 066)

## Approach
Add `iteratorCloseChecked(self, iterator) EvalError!Completion` next to `iteratorClose` (~4119):
§7.4.11 for a non-throw incoming completion — GetMethod return (undefined/null → `.normal`;
non-callable → TypeError), call it, propagate a thrown completion, TypeError on a non-object
result, else `.normal`.

In `evalForOf` (~742-763):
- `.brk`: `const cc = try iteratorCloseChecked(iterator); if (cc.isAbrupt()) return cc;` then the
  existing break/return-bc logic.
- loop-exiting labelled `.cont`: same checked close, propagate before `return bc`.
- split `.ret, .throw`: `.ret` uses the checked close (propagate); `.throw` keeps the void
  swallowing `iteratorClose` (§7.4.11 step 4 — original throw wins).
- abrupt-binding site (~739): unchanged (throw completion → swallow).

Scope: SYNC `for-of` only. The async `evalForAwaitOf` / `asyncIteratorClose` and the destructuring
`destrClose` have the same bug — separate milestones (M79+).

## Files touched
`src/interpreter.zig` (`iteratorCloseChecked` helper + evalForOf close sites).

## Risks
LOW-MED. Behavior change only on the previously-swallowed error path. The THROW-completion sites are
explicitly kept swallowing (regression guard 1). Conformance gate + guards cover it.

## Constitution Check
Correctness leads (§7.4.11) ✔; perf: only on loop-exit close, not the hot iteration path ✔.
