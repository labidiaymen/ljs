# M55 — Iterator constructor + %Iterator.prototype% + eager helpers

## Goal
Build the `Iterator` abstract constructor and `%Iterator.prototype%` (§27.1), and re-parent every
built-in iterator to it so the §27.1.4 helper methods are inherited. Implement the EAGER consumers
(`reduce`/`toArray`/`forEach`/`some`/`every`/`find`); the LAZY helpers
(`map`/`filter`/`take`/`drop`/`flatMap`) + `Iterator.from` are M56.

## Design
- **%Iterator.prototype%** (proto = %Object.prototype%): the eager helper methods (`iterator_helper`
  native, name-dispatched) + `[Symbol.iterator]()` returning `this`. Stashed under the `%IteratorPrototype%`
  sentinel so the runtime factories resolve it.
- **`Iterator` constructor** (abstract, §27.1.3.1): a direct call or `new Iterator()` (new_target is
  undefined or `%Iterator%` itself) throws `TypeError`; only a subclass `super()` (new_target is the
  subclass) succeeds — leveraging the M47 `native_new_target` slot. `.prototype` IS %Iterator.prototype%.
- **Re-parenting**: %GeneratorPrototype% and the array/string/collection iterator factories now create
  with [[Prototype]] = %Iterator.prototype% (new `iteratorProto()` accessor) instead of %Object.prototype%,
  so `g().reduce(...)`, `[...].values().toArray()`, `map.keys().forEach(...)` resolve the helpers.
- **Eager consumers** (`iteratorHelper`): GetIteratorDirect(`this`) (Object + read `next` once), then
  drive via `iterNextDirect` (cached next). `reduce` (optional seed; empty-without-seed → TypeError),
  `toArray`, `forEach`, `some`/`every`/`find` (short-circuit). A non-callable callback closes the
  iterator (IfAbruptCloseIterator); short-circuit + a throwing callback also close it.

## Gates
build / test / lint / **Iterator ↑** / language no-regression (re-parenting touches for-of/spread/
destructuring) / Array&Map&Set&String no-regression / bench perf:ok.

## Result
Iterator 14→364/1028 (1.4%→35.4%); +350. No regression: language 87.4%, Array/Map/Set/String unchanged,
bench perf:ok. Verified `new Iterator()`→TypeError, generator/array-iterator helpers, short-circuits.

## Deferred (M56)
Lazy helpers `map`/`filter`/`take`/`drop`/`flatMap` (Iterator Helper objects), `Iterator.from`
(WrapForValidIterator), `%Iterator.prototype%[Symbol.toStringTag]` accessor + `constructor` accessor.
