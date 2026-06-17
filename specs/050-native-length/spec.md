# M50 — per-native `length` (cross-cutting)

## Goal
Give every built-in function its `length` own property (§20.2.4.1) — the single highest-leverage and
lowest-risk remaining win. `length` was previously deferred (absent on all natives), so a `length.js`
test failed in EVERY built-in subtree (595 such files corpus-wide). Adding it is **purely additive**:
a correct value passes the test, a wrong/unknown value leaves it failing exactly as before — no test can
regress.

## Design
A single centralized `nativeLength(id, native_name)` in `object.zig`, consulted by `createNative`:
- For a family dispatched by `native_name` (array/string/math/reflect/collection/… methods) the length
  keys off the spec method name via a small comptime lookup table.
- For a single-purpose native (each Object static, each Promise combinator, the constructors) it is fixed
  by `id`.
- Returns `null` for an unknown/internal native (resolving functions, combinator elements, test hooks) →
  no `length` property emitted (unchanged behavior).

`length` is defined BEFORE `name` so OrdinaryOwnPropertyKeys lists it first (spec property order), with
attributes `{ writable:false, enumerable:false, configurable:true }`. Zero call-site churn: only
`createNative` changed, so every native (constructors, prototype methods, statics, getters) picks it up.

## Gates
build / test / lint / **broad built-ins ↑** / language no-regression / bench perf:ok.

## Result (built-ins conformance, before → after)
Array 74.0→76.0, Object 70.4→73.0, Map 69.6→75.1, Set 91.1→95.3, WeakMap 74.0→77.6, WeakSet 88.2→92.9,
Symbol 54.2→60.4, Reflect 69.3→77.8, Math 80.9→91.9, Number 59.7→63.2, Promise 53.3→55.0, Function
26.4→29.6, JSON 60.0→61.2, String →63.9 — **~+600 tests** in one additive change. language 87.3% (no
regression), bench perf:ok.

## Notes
A handful of `length` values for less-common methods may still be imperfect (each only costs its own
already-failing test, never a regression); refine opportunistically. The companion `name.js` tests are
largely already satisfied by `createNative`'s `name` property.
