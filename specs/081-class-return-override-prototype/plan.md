# Plan — 081

## Approach
All edits are localized to `src/interpreter.zig` (no parser/ast/builtin changes).

### 1. Derived-ctor return override — `finishCtorReturn`
`finishCtorReturn(fd, value)` is the single funnel for a class-constructor body's return
(explicit `return v` and implicit fall-off both route through it). Extend the existing
derived-ctor `undefined` guard: for `fd.is_derived_ctor`, if `value` is **not** an Object:
- `undefined` → keep the existing GetThisBinding check (ReferenceError if `super` not called);
- any other primitive → throw TypeError (step 13.c).
Object returns and all non-derived functions are untouched. `constructNT`'s existing
`result.isAbrupt()` propagation carries the throw out of `new`.

### 2. Constructor `prototype` attributes — `evalClass`
After wiring `proto` + the `constructor` back-link, redefine the ctor's `prototype` own
property with `defineData("prototype", proto, false, false, false)` so it is non-writable,
non-enumerable, non-configurable (`createFunction` had defaulted it writable).

### 3. Static `prototype` element guard — `evalClass` + helper
Add `staticPrototypeKeyError(is_static, key)`: when a static, non-private element's resolved
string key equals `"prototype"` (symbol keys excluded — always distinct), throw TypeError.
Call it after `classElementKey` in the method, get/set, and field branches. Instance elements
are unaffected (they install on `.prototype`, where `prototype` is a legal key).

## Files / functions touched
- `src/interpreter.zig`: `finishCtorReturn` (extend), `evalClass` (lock `prototype` attrs +
  3 guard call-sites), new helper `staticPrototypeKeyError`.

## Constitution check
- **Correctness-leads:** pure conformance fixes mapped to ECMA-262 clauses; verified with
  minimal repros + Test262 deltas.
- **Perf no-regression:** the guard is a single `is_static && eql` string compare per static
  element at class-definition time (cold path); `finishCtorReturn` adds one tag compare on the
  ctor-return path. No hot-path impact. `zig build bench` must stay green (ljs-vs-self ±15%).
- **No new files / no host APIs.**

## Risk
- The `prototype` attribute lock could in theory affect code that reassigns `C.prototype`;
  per spec that is correctly now a silent no-op (sloppy) / TypeError (strict assignment),
  matching the non-writable descriptor. Guarded by the full-language 0-regression gate.
