---
description: "Task list for M72 / 060 — SuperProperty write (assign / compound / logical / update)"
---

# Tasks: M72 — SuperProperty as an assignment/update target (§13.3.5/§6.2.5.6/§10.1.9.2)

One cycle, one commit (build + test + lint + conformance 0-regression + bench green).

- [x] T010 `ast.zig`: add `super_assign: struct { name, key: ?*const Node, value: *const Node }`.
- [x] T020 `parser.zig`: allow `.super_member` in the logical-assign + plain/compound assign target
  switches; break out plain `super.x = v` into `super_assign`. (Update-expr already parsed it;
  also handled `super_assign` in `containsArguments`.)
- [x] T030 `interpreter.zig`: `setSuperProperty(key, value)` — accessor on the super chain → call
  setter with `this = this_val`; otherwise `setProperty(this_val, key, value)` (receiver write).
- [x] T040 `interpreter.zig`: `evalExpr` `.super_assign` (eval computed key once → value → set).
- [x] T050 `interpreter.zig`: handle a `.super_member` target in compound-assign, logical-assign,
  and update (`++`/`--`) — read via `getSuperProperty`, write via `setSuperProperty`, key once.
- [x] T060 Local repros: 7/7 spec.md US1/US2 acceptance scenarios pass via `ljs run`.
- [x] T070 FULL gate: build/test/lint green; conformance 39016/43666 = **89.4%**, +12 vs M71,
  **0 regressions**; bench perf: ok. (No baseline change.)
