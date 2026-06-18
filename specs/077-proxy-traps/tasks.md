# 077 — Tasks

- [x] Add `Object.revoke_target` slot; keep the revoke closure callable (not a Proxy).
- [x] Proxy-aware ordinary internal-method helpers in interpreter.zig.
- [x] [[Get]] trap + invariant (existed; verified) + symbol/string + proto-chain delegation.
- [x] [[Set]] trap + invariant; string/symbol dispatch + proto-chain delegation; receiver-on-proxy.
- [x] [[HasProperty]] trap + invariant; `in` + Reflect.has + proto-chain delegation.
- [x] [[Delete]] trap + invariant; string/symbol; operator + Reflect.
- [x] [[GetOwnProperty]] trap + invariant; Object/Reflect.getOwnPropertyDescriptor.
- [x] [[DefineOwnProperty]] trap + invariants; Object/Reflect.defineProperty.
- [x] [[GetPrototypeOf]] / [[SetPrototypeOf]] traps + invariants; Object/Reflect.
- [x] [[IsExtensible]] / [[PreventExtensions]] traps + invariants; Object freeze/seal/isFrozen/isSealed.
- [x] [[OwnPropertyKeys]] trap + invariants (unique, non-config coverage, non-extensible exactness);
      Reflect.ownKeys, Object.keys/values/entries/getOwnPropertyNames/getOwnPropertySymbols/assign, JSON.
- [x] [[Call]] (apply trap) / [[Construct]] (construct trap) + invariant; isCallable/isConstructor.
- [x] Proxy/revoke function metadata (length/name/no prototype/not-a-constructor).
- [x] Gates: zig build / test / lint / bench green; built-ins/Proxy 21.7% → 78.4%; 0 language regressions.

## Deferred (out of reach this cycle)
- `*-realm.js` (73 cases): need `$262.createRealm` cross-realm host support — out of scope.
- A synthetic Array `length`/index inherited through a prototype chain is not seen by a forwarded
  [[HasProperty]] (pre-existing chain-walk limitation, not Proxy-specific).
- `with` statement + proxy `has` (a few sloppy-mode cases).
