---
description: "Task list for M71 / 059 — var hoisting to the VariableEnvironment"
---

# Tasks: M71 — `var` hoisting (§10.2.11 / §16.1.7 / §14.3.2.1)

One cycle, one commit (build + test + lint + conformance 0-regression + bench green).

- [x] T010 `environment.zig`: add `is_var_scope: bool` field + `varScope()` parent-walk helper.
- [x] T020 Mark the VariableEnvironments `is_var_scope = true`: global/script env (in
  `builtins.setup`), function `call_env`, generator/async `call_env`, direct-eval env (eval-local).
- [x] T030 `hoistVarNames`/`hoistVarNamesStmt`/`hoistVarPattern` in `interpreter.zig` mirroring the
  parser's `collectVarNames` traversal; declare each BoundName initialized-`undefined` iff absent.
- [x] T040 Call `hoistVarNames(body, scope)` after `hoistLexicalNames` at the three scope sites
  (script `run`, function body, generator/async).
- [x] T050 `.declaration` var path: route to `env.varScope()`; bare `var x;` no-op;
  `var x = e` assigns; pattern binds into the var scope.
- [x] T060 `bindForHead` var path: bind into `env.varScope()`, body runs in `env`.
- [x] T070 Local repros: all spec.md acceptance scenarios (US1–US3) pass via `ljs run` (12/12).
- [x] T080 FULL gate: `zig build` + `test` + `lint` all green; conformance 39004/43666 = **89.3%**,
  **+157 vs M70**, **0 regressions** vs baseline; `zig build bench` perf: ok (baseline re-recorded —
  see spec.md Outcome). Required 4 regression fixes (static-block var scope; var-init via `with`-aware
  declare; strict-eval var scope keyed on the eval body's strictness; class-name TDZ pre-binding).
