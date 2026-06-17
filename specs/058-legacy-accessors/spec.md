# M58 — legacy Object.prototype accessor helpers (§B.2.2)

## Goal
Implement the Annex B legacy methods `__defineGetter__` / `__defineSetter__` / `__lookupGetter__` /
`__lookupSetter__` on `Object.prototype` (§B.2.2.2–.5), previously absent.

## Design
One native (`object_legacy_accessor`, name-dispatched) + `objectLegacyAccessor`:
- **define**: ToObject(this); the function arg must be callable (else TypeError); install an
  `{ get|set, enumerable:true, configurable:true }` accessor via `defineProperty` /
  `defineSymbolProperty` (key through `toPropertyKey`, so Symbol keys work — building on M57).
- **lookup**: ToObject(this), `toPropertyKey`, then walk the prototype chain for an OWN property with
  the key; an accessor → return its get/set (or undefined if that half is absent); a data property →
  undefined (it shadows); chain exhausted → undefined.

## Gates
build / test / lint / **Object ↑** / language no-regression / bench perf:ok.

## Result
Object 5057→5137/6802 (74.3%→75.5%); +80. Ripple: language +8 (87.5%). No regression; bench perf:ok.
Verified define/lookup for data vs accessor and inherited accessors.
