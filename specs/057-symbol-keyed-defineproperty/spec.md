# M57 — Symbol-keyed Object reflection

## Goal
Make `Object.defineProperty` / `Object.defineProperties` / `Object.getOwnPropertyDescriptor` accept
**Symbol** keys (§20.1.2.4/.5/.8), previously broken — they `ToString`-coerced the key, so
`Object.defineProperty(o, sym, …)` stored under a bogus string and `getOwnPropertyDescriptor(o, sym)`
returned `undefined`.

## Design
- Refactor `Object.defineProperty`'s §10.1.6.3 ValidateAndApplyPropertyDescriptor merge into a shared
  `applyDescriptor(existing, d, extensible)` helper, then add a Symbol-keyed `defineSymbolProperty`
  operating over the `symbol_props` store (keyed by Symbol identity) with identical merge/reject logic.
- `objectDefineProperty` now resolves the key via `toPropertyKey` (Symbol stays a Symbol) BEFORE
  ToPropertyDescriptor (spec step order), routing a Symbol key to `defineSymbolProperty`.
- `objectGetOwnPropertyDescriptor` resolves via `toPropertyKey`; a Symbol key scans `symbol_props` and
  builds the descriptor via the existing `fromPropertyValue`.
- `objectDefineProperties` additionally iterates the source's enumerable **symbol-keyed** own properties
  (§20.1.2.5 OwnPropertyKeys includes Symbols), defining each via `defineSymbolProperty`.

## Gates
build / test / lint / **Object ↑** / language no-regression / bench perf:ok.

## Result
Object 4967→5057/6802 (73.0%→74.3%); +90. Ripple: language 87.4→87.5% (+32 — many tests define
symbol-keyed properties / use propertyHelper). No regression; bench perf:ok.

## Notes
The remaining `defineProperty`/`getOwnPropertyDescriptor` failures are non-Symbol: descriptor-edge cases
and Proxy-targeted tests (Proxy is a later milestone). Legacy `__defineGetter__`/`__lookupGetter__`
(§B.2.2, ~108 tests) are also still unimplemented.
