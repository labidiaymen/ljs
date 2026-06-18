# 077 — Plan

## Approach
Route every §10.5.x internal method through the Proxy handler trap (or forward to the target)
with the §10.5.x invariant checks. Two layers:

1. **`src/builtin_proxy.zig`** — one `pub fn` per trap (get/set/has/delete/getOwnProperty/
   defineProperty/getPrototypeOf/setPrototypeOf/isExtensible/preventExtensions/ownKeys/apply/
   construct). Each: revoked-check → GetMethod(handler, name) → absent ⇒ forward to the target's
   ordinary internal method; present ⇒ Call(trap), then the §10.5.x invariant validation.
2. **`src/interpreter.zig`** — proxy-aware ordinary internal-method helpers
   (`ordinaryGetOwnProperty[Symbol]`, `ordinaryDefineOwnProperty[Symbol]`, `ordinaryGetPrototypeOf`,
   `ordinarySetPrototypeOf`, `ordinaryIsExtensible`, `ordinaryPreventExtensions`, `ordinaryOwnKeys`)
   used both by the trap-forward path and by the proxy-aware Object/Reflect routing. Each dispatch
   site (`getProperty`/`getSymbolProperty`/`setProperty`/`setSymbolProperty`/`deleteProperty`/
   `in`/`hasPropertyVC`/`callFunction`/`constructNT`) gains a single `if (o.proxy)` branch BEFORE
   the ordinary path. `isCallable`/`isConstructor` derive a proxy's call/construct from its target.

A Proxy whose target is callable is marked `kind == .function` so `typeof`/IsCallable/[[Call]]
route to it; the `o.proxy != null` check precedes every ordinary-function path, so the proxy
never runs an ordinary call body.

Prototype-chain proxies: an ordinary [[Get]]/[[HasProperty]]/[[Set]] miss on the C-level chain
consults `protoProxy(o)` (the first Proxy on the prototype chain) and delegates to its trap with
`Receiver = base`.

## Object representation
`Object.proxy: ?*ProxyData` already existed. Added `Object.revoke_target: ?*ProxyData` so the
revoke closure (an ordinary callable native) stashes its Proxy without being mistaken for one.

## Constitution Check
- Correctness-leads: invariants implemented per §10.5.x; revoked proxy throws on every method.
- Perf no-regression: every non-Proxy object pays exactly one `o.proxy == null` test off the hot
  path; `zig build bench` shows no ljs-vs-self regression.
