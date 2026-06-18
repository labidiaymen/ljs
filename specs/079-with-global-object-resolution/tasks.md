# Tasks 079 — `with` + global-object identifier resolution

- [x] Reproduce the cluster: `statements/with` at 26.9% dominated by `unexpected_error`; minimal
      repro `this.p1 = 1; p1` → `ReferenceError`.
- [x] Add `globalObject()` / `globalObjectHas()` helpers (§9.1.1.4 object-record HasBinding).
- [x] Identifier read: consult the global object on a declarative-chain miss (both the `with`
      `.unresolved` arm and the ordinary path) before throwing `ReferenceError`.
- [x] `typeof`: treat a name as unresolved only when it misses the declarative chain, any enclosing
      `with` object, AND the global object.
- [x] Extract `putWithAwareIdentifier(name, value, env)` from `assignToTarget`; delegate.
- [x] Add `varInWithReach(env)`; route a single-identifier `var x = e` initializer inside a `with`
      through `putWithAwareIdentifier` (§14.3.2.3 PutValue) instead of a fresh with-env binding.
- [x] Spike (then revert): global `var`/function as own `globalThis` properties — regressed
      eval-code/variable/let/const/switch/delete; reverted, documented as deferred.
- [x] Gate: `zig build` / `zig build test` / `zig build lint` green.
- [x] Gate: `statements/with` 49→118 (+69); 0 regressions across measured dirs.
- [x] Gate: full `language/` baseline (`--baseline baseline/language.json`) exit 0.
- [x] Gate: `zig build bench` no ljs-vs-self regression.
- [x] Commit (spec folder + code) to the worktree branch; do not push.
