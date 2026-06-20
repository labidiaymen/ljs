# Spec 092 — eval code: EvalDeclarationInstantiation + indirect lexenv (§19.2.1)

Status: Done — eval-code/direct 182→320, indirect 92→100; language 41,526 → 41,672 (+146), 93.7%,
0 regressions, 0 panics, bench ok.
Owner: Aymen

## Fixes (§19.2.1 PerformEval / §19.2.1.3 EvalDeclarationInstantiation)
- **`arguments` in a parameter-scope direct eval is a SyntaxError** (§19.2.1.3 step 3.d) — the
  dominant cluster. `f(p = eval("var arguments"))`: the parameter env binds `arguments` between the
  eval's lexEnv and the body var scope, so declaring it collides. Added an `in_param_init` flag set
  during formal-parameter evaluation (gated on the param env actually binding `arguments`) and a
  `performEval` check that throws for a direct sloppy eval declaring `arguments` in that window.
- **Eval-introduced var/function bindings are deletable** — a sloppy direct eval hoisting into a
  non-global function var scope creates bindings with a `deletable` flag; `delete x` removes a local
  deletable binding; an eval top-level function declaration refreshes the var-scope binding in place.
- **Indirect eval gets a distinct lexical environment** (§19.2.1.1 steps 11–12) — wraps the global
  env in a fresh non-var-scope child so `let`/`const`/`class` stay eval-local while sloppy `var`s
  still hoist to the global var env.

Files: `environment.zig` (Binding.deletable), `interpreter.zig` (in_param_init, eval_var_deletable),
`interp_expr.zig` (param-init window, performEval check, local deletable delete), `interp_async.zig`
(param-init around generator/async param binding), `interp_stmt.zig` (eval-hoist deletable marking),
`interp_native.zig` (indirect eval child lexenv).

## Out of scope
- `var-env-*-init-global-*` / `non-definable-global-*`: need global declarative-env ↔ global-object
  var mirroring (a broad structural epic). `realm.js` ($262.createRealm).
