# Wave 2 — Promise tasks

- [x] Add `PromiseCapability` record + `promise_with_resolvers`/`promise_capability_executor` NativeIds
- [x] Re-type `PromiseReaction.capability` / `CombinatorState.capability` to `*PromiseCapability`
- [x] `newPromiseCapability(C)` + GetCapabilitiesExecutor body + `newBuiltinCapability` fast path
- [x] `isConstructorObj` (IsConstructor: arrows/methods excluded; proxy/bound/native ctors)
- [x] `speciesCapability(O)` — SpeciesConstructor(O, %Promise%) then NewPromiseCapability
- [x] `capabilityResolve`/`capabilityReject` (call the record's functions)
- [x] `then` → species capability; `catch`/`finally` → Invoke(this,"then")
- [x] `resolve`/`reject` use `this` as C; `withResolvers`
- [x] combinators: capability via C, GetPromiseResolve(C), `invokeThen`, `all_reject` variant
- [x] `promiseConstructor`: NewTarget guard + subclass-instance PromiseData
- [x] `runReactionJob`/`combinatorSettleIfDone` settle through capability functions
- [x] builtins.zig: length/name/@@species/@@toStringTag + withResolvers registration
- [ ] Gate: build/test/lint/bench green; language no-regression; Promise panics:0; before→after delta
