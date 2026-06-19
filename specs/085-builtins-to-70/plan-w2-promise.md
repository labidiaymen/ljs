# Spec 085 — Wave 2: Promise (§27.2) gap-fill

**Status:** In progress
**Goal:** recover the large `built-ins/Promise` failure pool (~624 fails) — capability-aware
combinators/`then`/statics, subclassing/species, `Promise.withResolvers`, and the
length/name/toStringTag/species attribute checks.

## Governing clauses
- §27.2.1.5 NewPromiseCapability / GetCapabilitiesExecutor
- §27.2.3.1 Promise constructor (NewTarget guard, OrdinaryCreateFromConstructor → subclass proto)
- §27.2.4.3 Promise.withResolvers; §27.2.4.4 reject; §27.2.4.7 resolve (PromiseResolve(C,x))
- §27.2.4.10 get Promise[@@species]; §7.3.22 SpeciesConstructor used by then/catch/finally
- §27.2.4.1/.2/.3/.6 combinators (all/allSettled/any/race): NewPromiseCapability(C) + GetPromiseResolve(C)
- §27.2.5.4 then (species capability), §27.2.5.1 catch (Invoke this.then), §27.2.5.3 finally (Invoke this.then)
- §27.2.5.5 Promise.prototype[@@toStringTag]

## Implementation (files touched)
- `src/runtime_types.zig`: new `PromiseCapability` record; `PromiseReaction.capability` +
  `CombinatorState.capability` retyped to `*PromiseCapability`; new NativeIds
  `promise_with_resolvers`, `promise_capability_executor`.
- `src/object.zig`: re-export `PromiseCapability`; new `capability: ?*PromiseCapability` field.
- `src/interp_async.zig` (the bulk — Promise-owned file):
  - `newPromiseCapability(C)` / `promiseCapabilityExecutor` / `newBuiltinCapability` (fast path) /
    `speciesCapability(O)` / `capabilityResolve`/`capabilityReject` / `isConstructorObj`.
  - `then`/`catch`/`finally` route through species capability / `Invoke(this,"then")`.
  - statics `resolve`/`reject`/`withResolvers` use `this` as constructor C.
  - combinators take `this` (C); build result capability via NewPromiseCapability(C); resolve each
    element through `C.resolve`; settle through capability functions; new `invokeThen` (calls the
    element's own `then`); `all_reject` element variant.
  - `promiseConstructor` honors NewTarget (TypeError w/o new) + attaches PromiseData to the
    pre-built subclass instance (`this_val`).
  - `runReactionJob` settles via `capabilityResolve`/`capabilityReject`.
- `src/interp_native.zig`: dispatch wiring (pass `this_val` to statics/combinators/ctor; new ids).
- `src/builtins.zig`: `Promise.length=1`; method `length` (then 2, others 1, withResolvers 0);
  `withResolvers`; `get Promise[@@species]`; `Promise.prototype[@@toStringTag]`.

## Constitution check
- Correctness-first: pure ECMAScript built-in library, in charter. No host APIs.
- Perf: the genuine-%Promise% fast path keeps direct settlement (no observable `then`/`constructor`
  reads) for the overwhelmingly common case; user-subclass/species pay the spec'd extra calls.
  Bench gate must stay `perf: ok`.

## Deferred
- Per-realm @@species subtleties beyond returning `this`; unhandled-rejection host hooks (no host).
