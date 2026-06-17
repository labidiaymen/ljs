# M47 — ES2024 Set set-algebra + collection subclassing

## Goal
Implement the seven ES2024 `Set.prototype` composition methods and fix keyed-collection subclassing,
raising `built-ins/Set` from the M46 baseline (55.0%, 420/764).

## Methods (§24.2.3)
All take a set-LIKE `other` (duck-typed via §24.2.1.2 **GetSetRecord** → `size`/`has`/`keys`, not
necessarily a real Set) and either return a fresh plain `Set` or a boolean:
- `union` — clone(this) + each of `other`'s keys.
- `intersection` / `difference` / `isDisjointFrom` — size-directed: if `this.size <= other.size`,
  iterate `this` calling `other.has`; else iterate `other.keys()` checking `this`'s [[SetData]]. The
  ordering is observable (tests count `has` calls), so the branch matches the spec exactly.
- `symmetricDifference` — clone(this), then for each of `other`'s keys: in `this` ⇒ remove, else add.
- `isSubsetOf` / `isSupersetOf` — size short-circuit, then membership scan (IteratorClose on early
  `false` for the `other.keys()`-iterating methods).

`-0` is normalized to `+0` before storage/comparison; results are always `new Set` via
OrdinaryObjectCreate(%Set.prototype%) — NOT species (a `class X extends Set` union returns a base Set).

Lives in `interpreter.zig` `setAlgebra` (needs the private iterator-protocol helpers); `setMethod`
brand-checks `this` as a Set then delegates.

## Collection subclassing fix
`class X extends Map/Set/WeakMap/WeakSet { constructor(){ super() } }` routed `super()` →
`runParentCtor` → `callFunction(<ctor>)` → `callNative`, which threw "requires 'new'". Added a
`native_new_target` slot: `callFunction` copies the one-shot `pending_new_target` into it before each
native dispatch, so a collection constructor reached through a `super(...)` chain (new-target defined)
initializes the [[…Data]] slot on the derived `this`, while a plain call (`Map()`, undefined) still
throws. The top-level `new` path is unaffected (handled in `constructNT` before any native dispatch).

## Gates
build / test / lint / **Set ↑** / Map & WeakMap & WeakSet no-regression / language no-regression /
bench perf:ok.

## Result
Set 420→696/764 (55.0%→91.1%). Subclass support also lifts language conformance (+24). Remaining Set
failures are systemic: per-native `.length` (deferred engine-wide) and a few Symbol.species/cross-realm
cases. WeakMap/WeakSet still 71.2%/85.9% (those gains are M48 metadata, not algebra).
