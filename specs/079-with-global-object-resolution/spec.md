# Spec 079 — `with` + global-object identifier resolution

**Status:** Done — language `statements/with` 49 → 126 passing (26.9% → 69.2%, +77),
language headline 39855/44475 (89.6%), 0 regressions vs `baseline/language.json`.

## Summary

Two related scope/identifier-resolution gaps, sharing one root cause: ljs kept the global
namespace in two disconnected views — a declarative global Environment Record (`var`/`let`/
function/builtin bindings) and the reified global object (`globalThis`, where `this.x = …`
and `Object.defineProperty(globalThis, …)` land). A bare identifier that missed the declarative
chain threw `ReferenceError` even when the name was a property of the global object. This is the
§9.1.1.4 GlobalEnvironmentRecord *object record* half (`HasBinding`/`GetBindingValue`), which was
never consulted on resolution.

Additionally, a `var x = e` *initializer* lexically inside a `with` minted a fresh binding in the
throwaway with-environment instead of performing PutValue through the `with` binding object
(§14.3.2.3).

## Governing clauses

- §9.1.1.4.1 HasBinding / §9.1.1.4.6 GetBindingValue (GlobalEnvironmentRecord object-record half).
- §9.1.2.2 / §9.1.1.2 ObjectEnvironmentRecord resolution for `with`.
- §14.3.2.3 VariableDeclaration: a `var x = e` is `PutValue(ResolveBinding("x"), e)`.
- §13.5.3 `typeof` of an unresolved reference → `"undefined"` (must still consult the object record).

## User scenarios (Given/When/Then)

1. **Global-object property resolves as a bare identifier.**
   Given `this.p1 = 1;` at global (sloppy) scope · When `p1` is read as a bare identifier · Then it
   evaluates to `1` (not `ReferenceError`). (Unblocks the S12.10_A1.* `with` family, which seeds
   globals via `this.p = v`.)

2. **`with` body reads a global-object-installed name.**
   Given a `with (obj) { … }` whose body references a name absent from `obj` and the declarative
   chain but present on `globalThis` · When the name is resolved · Then it resolves to the global
   object property.

3. **`var x = e` inside `with`, name present on the binding object.**
   Given `var o = {x:1}; with (o) { var x = 99; }` · Then `o.x === 99` (PutValue through the binding
   object), and a `var y = 5` whose name is absent from `o` writes the hoisted global/function var,
   not a property of `o`.

4. **`typeof` of a global-object-only name reports its real type, not `"undefined"`.**

## In scope

- Identifier read, `with`-path read, and `typeof` consult the global object on a declarative miss.
- `var`-initializer-in-`with` routed through the with-aware PutValue.

## Out of scope (deferred — regression-prone, attempted and reverted)

- Making top-level Script / eval global `var`/function declarations *own properties* of `globalThis`
  (§16.1.7 CreateGlobalVarBinding / CreateGlobalFunctionBinding). A spike making the global object the
  canonical store for global `var`/function regressed `eval-code`, `statements/variable`, `let`,
  `const`, `switch`, and `delete` broadly (strict global-var configurability, `let`/`var` global
  redeclaration checks, `delete` of globals). Left for a dedicated milestone with a full
  GlobalEnvironmentRecord model. The `eval-code` `var-env-*-global-*` cluster remains the next lever.

## Success criteria

- `statements/with` conformance rises materially (achieved: +69).
- 0 regressions across `language/` vs `baseline/language.json`.
