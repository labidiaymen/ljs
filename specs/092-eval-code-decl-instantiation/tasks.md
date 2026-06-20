# Tasks — Spec 092
- [x] T1. environment: Binding.deletable.
- [x] T2. interp_expr/interp_async: in_param_init window; performEval `arguments` SyntaxError.
- [x] T3. interp_stmt: eval-hoisted var/func bindings deletable; func-decl refresh in place.
- [x] T4. interp_native: indirect eval runs in a fresh child lexenv of the global env.
- [x] T5. Gate: build/test/lint/bench green; eval-code/direct 182→320, indirect 92→100; language
      41,526→41,672 (+146), 0 regressions, 0 panics.
