# Spec 096 — instanceof: Symbol.hasInstance + OrdinaryHasInstance (§13.10, §7.3.22)

Status: Done — expressions/instanceof 57→85 (100%); language 42,152 → 42,187 (+35), 94.8%→94.9%,
0 regressions, 0 panics, bench ok. Owner: Aymen

## Fixes
- `evalBinary`'s `instanceof` called a legacy byte-walking helper that never consulted
  `Symbol.hasInstance`, read `prototype` directly (no getter / no abrupt), and returned `false`
  instead of throwing TypeError for a non-object/non-callable RHS or non-object `prototype`. Replaced
  with `instanceofOperator` (§7.3.22: GetMethod(@@hasInstance) → ToBoolean(Call); else IsCallable
  check + §7.3.21 OrdinaryHasInstance, which was already correct).
- Bug fix: an ordinary function's auto-created `.prototype` object had a null `[[Prototype]]`;
  `finalizeFunctionPrototype` now links it to `%Object.prototype%` (§10.2.4) — latent correctness
  bug affecting every user function (`Object.getPrototypeOf(F.prototype)`), surfaced by
  `(new F) instanceof Object`.

Files: interp_ops.zig (instanceofOperator), interp_expr.zig (finalizeFunctionPrototype proto link),
abstract_ops.zig (drop dead instanceOf helper).
