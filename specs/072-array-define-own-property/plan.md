# Plan 072

## Files touched
- `src/builtin_object.zig`
  - `objectDefineProperty`: array branch routes `length` → `arrayDefineLength`, integer index →
    new `arrayDefineIndex`.
  - new `arrayIndex(key)`: §10.4.2 IsArrayIndex (canonical numeric string `< 2^32-1`).
  - new `arrayDefineIndex(it, arr, i, key, d)`: §10.4.2.1 — presence in dense store *or* property map,
    extensibility / non-writable-length rejection, §10.1.6.3 redefinition guards, default-attribute
    data → dense element store + `[[Length]]` growth, non-default/accessor → property map (and delete
    any prior dense slot to avoid double-counting).
  - `objectDefineProperties`: array `length`/index routing (was a plain `defineProperty`).
  - `objectGetOwnPropertyDescriptor`: array index consults the property map first (non-default attrs),
    then the dense store.
- `src/builtin_reflect.zig`
  - `reflectSet`: §10.1.9 receiver redirection via `setOnReceiverStr` / `setOnReceiverSym`.
  - `Reflect.defineProperty`: integer-index routing into `arrayDefineIndex`.

## Design calls
- The dense element store cannot express per-index attributes, so an index is held in *exactly one*
  of {dense store, property map}. The representable (default-attribute data) case stays dense (hot
  path, interpreter reads work); everything else lives in the map.
- `arrayDefineIndex` takes the caller's arena-owned canonical `key` string — the property map stores
  key slices by reference, so a stack buffer would dangle.
- `Reflect.defineProperty` maps a rejected `arrayDefineIndex` (TypeError completion) to `false`;
  array `length` keeps the store-backed path so its RangeError still propagates.

## Constitution check
- Correctness-leads: pure conformance fix, spec-clause-anchored.
- Perf: the array index *read*/*write* hot paths (interpreter) are untouched; the new logic runs only
  in `Object.defineProperty(ies)` / `Reflect.*`, which are not perf-hot. `zig build bench` gate must
  show no regression.
