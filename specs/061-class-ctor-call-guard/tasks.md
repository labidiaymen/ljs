---
description: "Task list for M73 / 061 — class constructor [[Call]] guard on every entry path"
---

# Tasks: M73 — class constructor [[Call]] guard (§15.7.14)

- [x] T010 `interpreter.zig` `callFunction`: guard added after the `pending_new_target` consume,
  before the bound-function unwrap.
- [x] T020 Local repros: US1 (call/apply/bind/derived) all throw TypeError; regression guards
  (new / super / new-bound / ordinary-fn `.call`) all still work.
- [x] T030 FULL gate: build/test/lint green; conformance 39020/43666 = 89.4%, +4 vs M72, 0 regressions; bench perf: ok.
  Record the delta in spec.md Status.
