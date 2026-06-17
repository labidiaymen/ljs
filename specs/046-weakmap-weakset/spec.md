# M46 — WeakMap & WeakSet

## Goal
Implement `WeakMap` (§24.3) and `WeakSet` (§24.4) from **0.0%**, reusing the M45 collection backing
store (`object.zig` `Collection`, see [045-map-set](../045-map-set/spec.md)).

## Design
The constructors were already routed through `constructNT` → `initCollectionInstance` in M45 (all four
collection kinds), so M46 adds only the prototype methods + registration:
- **WeakMap.prototype**: `get` / `set` (→ `this`) / `has` / `delete` (§24.3.3). No `size`, no `clear`,
  no `forEach`, no iteration — a WeakMap is not enumerable.
- **WeakSet.prototype**: `add` (→ `this`) / `has` / `delete` (§24.4.3).
- `[Symbol.toStringTag]` = `"WeakMap"` / `"WeakSet"`. No `Symbol.species`, no `[Symbol.iterator]`.

### Key constraint — CanBeHeldWeakly (§7.3)
A key must be an Object or a Symbol that is NOT in the GlobalSymbolRegistry. The engine has no
`Symbol.for` registry, so every Symbol qualifies. `set`/`add` throw `TypeError` on a non-weak-holdable
key; `get`/`has`/`delete` treat it as a silent miss (return `undefined`/`false`, no throw).

### Memory model
The store holds keys strongly (no GC / liveness reclamation). This is observationally correct for all
of Test262's WeakMap/WeakSet conformance — those tests check semantics, not collection. Real weak
reclamation is out of scope (no GC in the tree-walker).

## Gates
build / test / lint / **WeakMap ↑, WeakSet ↑ from 0** / Map & Set no-regression / language
no-regression / bench perf:ok.

## Result
WeakMap 0→200/281 (71.2%), WeakSet 0→146/170 (85.9%). Ripple: the Map/Set brand tests that construct a
WeakMap/WeakSet to assert cross-kind rejection now pass — Map 64.2%→69.6%, Set 53.1%→55.0%.

## Deferred
ES2024 Set set-algebra methods (M47). Registered-symbol (`Symbol.for`) exclusion from CanBeHeldWeakly
(needs a global symbol registry — a handful of edge tests).
