# Plan 079 — `with` + global-object identifier resolution

## Approach

All edits are in `src/interpreter.zig` (the statement/scope/eval subsystem).

### 1. Global-object record fallback (the +69 lever)

- `globalObject()` — the reified `%GlobalThis%` as `*Object`, or null.
- `globalObjectHas(name)` — §9.1.1.4.1 object-record HasBinding: `globalObject().get(name) != null`
  (HasProperty over the proto chain). The `%…%` realm sentinels live only in the declarative env,
  never as object properties, so they cannot leak.
- Identifier read (`evalExpr .identifier`): on a declarative-chain miss (both the `with`-path
  `.unresolved` arm and the ordinary path) consult `globalObjectHas`; if present, `getProperty` from
  the global object instead of throwing `ReferenceError` (§9.1.1.4.6 GetBindingValue).
- `typeof` (`evalUnary`): a name is "unresolved" (→ `"undefined"`) only when it misses the
  declarative chain, any enclosing `with` object (`resolveIdRef`), AND the global object; otherwise
  fall through to evaluate and report the real type.

### 2. `var x = e` initializer inside `with` (§14.3.2.3)

- `varInWithReach(env)` — true iff a `with` object Environment Record sits between `env` and the
  nearest VariableEnvironment.
- In the `.declaration` var path: when the target is a single identifier with an initializer and we
  are lexically inside a `with`, route the assignment through `putWithAwareIdentifier` (PutValue via
  the with binding object / hoisted var binding) rather than `target_env.declare` into the
  throwaway with-env.
- `putWithAwareIdentifier(name, value, env)` — extracted from the `assignToTarget` identifier arm
  (the with-aware ResolveBinding + SetMutableBinding) so the var-initializer and assignment paths
  share one implementation. `assignToTarget` now delegates to it.

## Files / functions touched

- `src/interpreter.zig`: `globalObject`, `globalObjectHas` (new); `evalExpr` identifier read arm;
  `evalUnary` `typeof` arm; `.declaration` var-init arm; `varInWithReach` (new);
  `putWithAwareIdentifier` (new, extracted) + `assignToTarget` delegation.

## Constitution check

- **Correctness leads.** Pure conformance fix; the read fallback is a SLOW path (fires only on a
  declarative-chain miss), so the hot identifier path is unchanged.
- **Perf no-regression.** The added work is gated behind `env.lookup(name) == null` (a miss) and,
  for `typeof`, behind the existing `env.lookup == null` guard. Resolved bindings never reach it.
  `zig build bench` must show no ljs-vs-self regression.

## Risk

Eval/with/scope changes are regression-prone. Mitigation: the global-object fallback only fires on a
declarative miss (so existing declarative resolution is untouched); the `var`-in-`with` reroute is
gated on `with_depth > 0 and varInWithReach`. Verified 0 regressions across all measured dirs and the
full `language/` baseline. The broader global-`var`/function-as-object-property change was attempted,
measured to regress, and reverted — left to a future milestone (see spec Out of scope).
