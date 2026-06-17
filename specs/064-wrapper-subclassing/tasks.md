---
description: "Task list for M76 / 064 — primitive-wrapper subclassing"
---
# Tasks: M76 — primitive-wrapper subclassing (Boolean/Number/String)
- [x] T010 number_ctor/string_ctor/boolean_ctor: box the coerced primitive onto `this_val` when
  constructed (native_new_target defined + object this); else return the primitive.
- [x] T020 Remove the redundant `constructNT` wrapper boxing (~1824).
- [x] T030 Local repros: US1 + regression guards pass.
- [x] T040 FULL gate: build/test/lint green; conformance 39046 = 89.4%, +6 vs M75, 0 regressions; bench ok.
