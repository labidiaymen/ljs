# M49 — Symbol completeness (registry + description + toPrimitive + well-knowns)

## Goal
Raise `built-ins/Symbol` from 28.6% (55/192) by filling the self-contained gaps: the
GlobalSymbolRegistry, `description`, `[Symbol.toPrimitive]`, and the missing well-known symbols.

## Changes
1. **Well-known symbols** (§20.4.2): add `match`, `matchAll`, `replace`, `search`, `split`,
   `isConcatSpreadable` to the registered set (they were simply absent → `Symbol.match` etc. undefined).
2. **GlobalSymbolRegistry** (§20.4.2.2/.6): `Symbol.for(key)` returns the same Symbol per string key
   (created on first use); `Symbol.keyFor(sym)` returns its registry key (TypeError on a non-Symbol).
   Backed by a realm-lifetime `symbol_registry` map on the interpreter + a `registry_key` field on
   `Symbol`. **Ripple:** §7.3 CanBeHeldWeakly now excludes a registered symbol, so WeakMap/WeakSet
   reject a `Symbol.for(...)` key (WeakMap 71.2→74.0%, WeakSet 85.9→88.2%).
3. **`get Symbol.prototype.description`** (§20.4.3.2): accessor returning [[Description]] (or undefined).
4. **`Symbol.prototype[Symbol.toPrimitive]`** (§20.4.3.5) + ThisSymbolValue unwrapping of a Symbol
   wrapper object — `valueOf` / `[Symbol.toPrimitive]` return the Symbol; `toString` stringifies.
   `Symbol.prototype[Symbol.toStringTag]` = `"Symbol"`.

## Gates
build / test / lint / **Symbol ↑** / WeakMap & WeakSet no-regression / language no-regression /
bench perf:ok.

## Result
Symbol 55→104/192 (28.6%→54.2%); +49. Ripple: WeakMap +8, WeakSet +4, language +4 (87.3%). Remaining
Symbol failures are systemic (per-native `.length`, accessor descriptor metadata) — diminishing returns.
