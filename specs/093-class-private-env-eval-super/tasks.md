# Tasks — Spec 093
- [x] T1. PrivateName/PrivateEnv types; evalClass mints unique private names + pushes PrivateEnv.
- [x] T2. resolvePrivateKey (ResolvePrivateIdentifier); private get/set/in resolve via the chain.
- [x] T3. Ordered instance fields with per-field brand add; declaration-order TypeError.
- [x] T4. parseEvalMode + EvalContext for direct-eval super/new.target/private/arguments.
- [x] T5. PrivateEnvironment propagation through function/async/generator/arrow bodies.
- [x] T6. super-return rebind gated to user (non-native) parents (subclass-builtins fix).
- [x] T7. Split interp_expr → interp_eval.zig (under 2000-line budget).
- [x] T8. Gate: build/test/lint/bench green; full language sweep, 0 regressions vs baseline, 0 panics.
