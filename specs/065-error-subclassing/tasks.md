---
description: "Task list for M77 / 065 — Error / NativeError subclassing"
---
# Tasks: M77 — Error subclassing (§20.5.1.1 / §15.7.14)
- [x] T010 `error_ctor`: use `this_val.object` as the error when constructed (native_new_target
  defined + object this); else create fresh. Keep error_data/name/message logic.
- [x] T020 Local repros: US1 (extends Error/TypeError, message, instanceof, toString tag) +
  regression guards pass.
- [x] T030 FULL gate: build/test/lint green; conformance 39048 = 89.4%, +2 vs M76, 0 regressions; bench ok.
