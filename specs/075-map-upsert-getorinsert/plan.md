# Plan 075 — Map/WeakMap getOrInsert / getOrInsertComputed

## Approach
Two new shared helpers in `src/builtin_collection.zig`, dispatched from the existing
`mapMethod` (`.map_method`) and `weakMapMethod` (`.weakmap_method`) by `native_name`:

- `getOrInsert(it, coll, args, weak)`:
  1. (weak) CanBeHeldWeakly(key) else TypeError.
  2. `k = normKey(key)` (CanonicalizeKeyedCollectionKey, -0→+0).
  3. If `findIndex(coll, k)` → return existing value.
  4. Else append `{k, value}`, size++, return value.

- `getOrInsertComputed(it, coll, args, weak)`:
  1. (weak) CanBeHeldWeakly(key) else TypeError.
  2. IsCallable(callbackfn) else TypeError — BEFORE the lookup (spec step 3).
  3. `k = normKey(key)`.
  4. If present → return existing value (callback NOT called).
  5. `Call(cb, undefined, « k »)`; abrupt → propagate (nothing inserted).
  6. Re-resolve slot: if callback inserted `k`, overwrite its value; else append. Return value.

`findIndex` uses SameValueZero, which equals SameValue once the key is canonicalized (the only
SameValue/SameValueZero divergence is -0/+0, already collapsed by `normKey`).

## Registration (`src/builtins.zig`)
New `defineMethodLen` helper = `defineMethod` + a `length` own data property
(`{writable:false, enumerable:false, configurable:true}`), because the upsert Test262 cases read
`.length` (= 2) — the existing `defineMethod` defers `length`. Register all four methods
(Map + WeakMap × {getOrInsert, getOrInsertComputed}) with length 2.

## Files touched
- `src/builtin_collection.zig` — 2 helpers + 4 dispatch arms.
- `src/builtins.zig` — `defineMethodLen` helper + 4 registrations.

## Constitution check
- Correctness-leads: pure conformance work, spec-faithful step order.
- Perf no-regression: the helpers are off the hot path (collection mutation only); no change to
  existing get/set/has/delete/forEach paths. `defineMethodLen` runs once at realm setup. Bench
  gate must stay green.
