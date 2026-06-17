# M45 — Map & Set (keyed collections)

## Goal
Implement the ECMAScript keyed collections `Map` (§24.1) and `Set` (§24.2) from scratch, raising
`built-ins/Map` (405 tests) and `built-ins/Set` (764 tests) from **0.0%**. This milestone builds the
shared collection backing store + the collection-iterator machinery; `WeakMap`/`WeakSet` (M46) and the
ES2024 Set composition methods (`union`/`intersection`/`difference`/… — M47) reuse it.

## Diagnosis
`Map`/`Set`/`WeakMap`/`WeakSet` are all at 0% — the constructors are not registered at all
(`builtins.zig` has no `"Map"`/`"Set"`; `object.zig` `Kind` has no collection variant and there is no
backing store). Foundational: other suites construct Maps/Sets, so this ripples beyond the 1169 direct
tests.

## Design
### Backing store (`object.zig`)
A `Collection` attached to an ordinary object via a new optional slot `collection: ?*Collection`
(zero-cost for every non-collection object, mirroring `iter`/`generator`/`promise`):
- `entries: ArrayListUnmanaged(Entry)` — **insertion-ordered**; `Entry = { key, value, present }`.
- Deletion leaves a **tombstone** (`present=false`) so iterators created earlier still advance
  correctly (§24.1.5.2: a Map Iterator visits entries added during iteration and skips removed ones).
- `size` counts present entries (excludes tombstones).
- Key equality: **SameValueZero** (`abstract_ops.sameValueZero` — already present). The stored key
  normalizes `-0 → +0` (§24.1.3.9 / §24.2.3.1 note).
- Lookup is a linear scan over `entries` (correctness-first; collection conformance tests are about
  semantics, not scale).

### Constructors (§24.1.1 / §24.2.1)
Handled in `constructNT` (where `new_target.prototype` is in hand → subclass support). The four
collection natives are added to the `constructible` list; the `callNative` (without-`new`) path throws
`TypeError` "requires 'new'". `initCollectionInstance` attaches a fresh `Collection`, then
**AddEntriesFromIterable** (§24.1.1.2): if the iterable arg is non-nullish, get the instance's (possibly
overridden) `set`/`add` adder, then for each iterated record call the adder — for Map each record must
be an object whose `[0]`/`[1]` are key/value.

### Prototype methods
- `Map.prototype`: `get`, `set` (returns `this`), `has`, `delete` (→ boolean), `clear`, `forEach`
  (callbackfn + thisArg, visits live entries in order), `keys`/`values`/`entries` (→ Map Iterator),
  `[Symbol.iterator]` === `entries`, `get size` accessor, `[Symbol.toStringTag]` = `"Map"`.
- `Set.prototype`: `add` (returns `this`), `has`, `delete`, `clear`, `forEach`, `values`,
  `keys` === `values`, `entries` (→ `[v,v]` pairs), `[Symbol.iterator]` === `values`, `get size`,
  `[Symbol.toStringTag]` = `"Set"`.
- `get Map[Symbol.species]` / `get Set[Symbol.species]` return `this` (§24.1.3.10 / §24.2.3.10).

### Iterators (§24.1.5 / §24.2.5)
Extend `IterState` with a `collection: ?*Object` slot (cursor walks `entries`, skipping tombstones).
A Map/Set Iterator is an ordinary object carrying this slot + a `next` native; `iteratorNext`
gains a collection branch yielding `key` / `value` / `[key,value]` per `IterKind`.

## Gates
build / test / lint / **built-ins/Map ↑ from 0**, **built-ins/Set ↑ from 0**, 0 within-Map/Set
regression / language no-regression / bench perf:ok.

## Deferred
`WeakMap`/`WeakSet` (M46 — same store, no iteration, object/symbol-only keys). ES2024 Set methods
`union`/`intersection`/`difference`/`symmetricDifference`/`isSubsetOf`/`isSupersetOf`/`isDisjointFrom`
(M47 — GetSetRecord + set-algebra). `Map.groupBy`/`Map.prototype` edge metadata as they surface.
