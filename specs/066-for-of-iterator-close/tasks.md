---
description: "Task list for M78 / 066 — for-of IteratorClose error propagation"
---
# Tasks: M78 — for-of IteratorClose error propagation (§7.4.11)
- [x] T010 `iteratorCloseChecked` helper (propagate return() throw / non-object TypeError).
- [x] T020 evalForOf: checked close at break + loop-exiting-continue + `.ret`; keep void swallow at
  `.throw` and the abrupt-binding site.
- [x] T030 Local repros: US1 (propagate on break/return, non-object TypeError) + regression guards
  (throw-wins, clean return, array fast-path) pass.
- [x] T040 FULL gate: build/test/lint green; conformance 39056 = 89.4%, +8 vs M77, 0 regressions; bench ok.
