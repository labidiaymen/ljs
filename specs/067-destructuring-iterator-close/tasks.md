---
description: "Task list for M79 / 067 — array-destructuring IteratorClose error propagation"
---
# Tasks: M79 — array-destructuring IteratorClose (§7.4.11)
- [x] T010 `destrCloseChecked(rec)` delegating to `iteratorCloseChecked` for a not-done iterator.
- [x] T020 Use it at the two normal-completion sites (bindPattern ~2989, assignPattern ~3102);
  keep the void `destrClose` at the abrupt sites.
- [x] T030 Local repros: US1 (propagate on var/assignment destructuring, non-object TypeError) +
  regression guards (abrupt default wins, rest drain, fast-path, clean return) pass.
- [x] T040 FULL gate: build/test/lint green; conformance 39108 = 89.6%, +52 vs M78, 0 regressions; bench ok.
