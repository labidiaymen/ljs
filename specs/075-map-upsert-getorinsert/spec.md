# Spec 075 — Map/WeakMap upsert: getOrInsert & getOrInsertComputed

Status: Done (delta below)

## Summary
Implement the TC39 "upsert" proposal methods on `Map.prototype` and `WeakMap.prototype`:
`getOrInsert(key, value)` and `getOrInsertComputed(key, callbackfn)`. These were entirely
absent (`typeof Map.prototype.getOrInsert === "undefined"`), so every Test262 case under the
four `prototype/getOrInsert*` directories threw at setup — the single largest failing cluster
across Map/Set/WeakMap/WeakSet (96 of 174 failing strict+sloppy executions).

## Governing clauses
- §24.1.4 `Map.prototype.getOrInsert ( key, value )`
- §24.1.4 `Map.prototype.getOrInsertComputed ( key, callbackfn )`
- §24.3.4 `WeakMap.prototype.getOrInsert ( key, value )`
- §24.3.4 `WeakMap.prototype.getOrInsertComputed ( key, callbackfn )`
- §7.3 CanonicalizeKeyedCollectionKey (-0 → +0), CanBeHeldWeakly (WeakMap key validity)

## User scenarios (Given/When/Then, derived from Test262)
- Given a Map without `key`, When `getOrInsert(key, value)`, Then `value` is appended and returned;
  size grows by 1. Given the key present, Then the existing value is returned unchanged.
- Given `-0` as key, When inserted via getOrInsert*, Then the observable/canonical key is `+0`
  (CanonicalizeKeyedCollectionKey), and the callback receives `+0`.
- `getOrInsertComputed`: When key absent, callback is `Call(cb, undefined, « canonicalKey »)`
  (this===undefined, exactly one arg). When key present, the callback is NOT evaluated and the
  existing value is returned.
- IsCallable(callbackfn) is checked BEFORE the lookup: a non-callable callback throws TypeError
  even when the key is already present.
- If the callback throws, nothing is inserted and the throw propagates; prior mutations the
  callback performed on the collection persist.
- If the callback itself inserts the same key, the computed return value overwrites that slot.
- WeakMap variants throw TypeError on a non-weak-holdable key (primitive other than a
  non-registered Symbol).
- `.length === 2`, `.name` correct, non-enumerable/writable/configurable; not a constructor.

## In scope
`Map.prototype` + `WeakMap.prototype` getOrInsert / getOrInsertComputed, behavior + property
descriptors (incl. `length`). Reuses the existing `.map_method` / `.weakmap_method` native
dispatch and the `Collection` backing store.

## Out of scope
Set/WeakSet (the proposal defines no Set upsert). `Map.groupBy` / `Set` set-algebra realm tests,
and per-native `length` for the broader method surface (pre-existing engine gap).

## Success criteria / measured delta
All four `prototype/getOrInsert*` directories at 100%. Map built-ins area 318→360 /405,
WeakMap 222→269 /281. Zero language regressions.
