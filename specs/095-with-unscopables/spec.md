# Spec 095 — `with` statement + @@unscopables (§14.11, §9.1.1.2)

Status: Done — statements/with 126→177; language 42,082 → 42,152 (+70), 94.6%→94.8%, 0 regressions,
0 panics, bench ok. Owner: Aymen

## Fixes
`with`-binding resolution used a crude `obj.get(name) != null` that ignored `@@unscopables`, swallowed
proxy/getter errors, and bypassed the §9.1.1.2.x ObjectEnvironmentRecord operations.
- §9.1.1.2.1 HasBinding now consults `[Symbol.unscopables]` (a truthy entry hides the with-binding →
  resolution falls through to the outer scope), via a new `withHasBinding`.
- Abrupt completions (proxy `has`/getter throws) propagate (new `IdRef.abrupt`); §9.1.1.2.5/.6
  `withSetMutableBinding`/`withGetBindingValue` re-`HasProperty` (step 2).
- `delete name` and `++`/`--` inside `with` are now with-object-aware.
- `for (var k in …)` inside `with` binds the loop var on the real var scope (`varScopeSkipWith`).
- Parser: `with (…) function f(){}` is a §14.11.1 early error.

Files: interpreter.zig (IdRef.abrupt), interp_stmt.zig (withHasBinding/Get/Set, varScopeSkipWith),
interp_expr.zig (thread .abrupt; with-aware delete + inc/dec), parser.zig (early error).
