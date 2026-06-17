---
description: "Task list for M74 / 062 — class heritage prototype validation"
---

# Tasks: M74 — class heritage `prototype` validation (§15.7.14)

- [x] T010 `interpreter.zig` `evalClass` heritage `.object` arm: replace the object-only prototype
  read with a switch — object → link; null → ok; other present primitive → TypeError.
- [x] T020 Local repros: spec.md US1 (prototype = 42 / "x" / undefined) throw TypeError;
  regression guards (prototype = null, `extends B`, `extends null`) still work.
- [x] T030 FULL gate: build/test/lint green; conformance 39026/43666 = 89.4%, +6 vs M73, 0 regressions; bench ok.
  Record the delta in spec.md Status.
