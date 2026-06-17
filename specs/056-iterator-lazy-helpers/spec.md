# M56 — lazy Iterator helpers + Iterator.from

## Goal
Complete the §27.1.4 iterator helpers with the LAZY methods (`map`/`filter`/`take`/`drop`/`flatMap`) and
`Iterator.from` (§27.1.3.1.1), building on M55's `%Iterator.prototype%` scaffolding.

## Design
- **Iterator Helper object** (`object.zig` `HelperState` + `iter_helper` slot): proto =
  %Iterator.prototype%, with its own `next`/`return` natives (`iterator_helper_next`). Holds the
  underlying iterator + its cached `next`, the kind, the callback, an index counter, a take/drop
  countdown, and (for flatMap) the current inner iterator. `done` latches on exhaustion/close.
- **Lazy methods** (`iteratorHelper` for map/filter/flatMap; `iteratorLimitHelper` for take/drop, which
  validate a numeric limit — `ToNumber`→NaN/negative throw `RangeError`, closing the underlying). Each
  returns a fresh helper.
- **`helperNext`** drives the transform per kind: `map` (apply cb), `filter` (loop until cb truthy),
  `take` (countdown then stop+close), `drop` (skip N once, then passthrough), `flatMap` (flatten each
  mapped value via GetIteratorFlattenable, reject primitives), `wrap` (identity, for `Iterator.from`).
  A throwing callback / inner abrupt closes the underlying; `return` closes underlying + inner.
- **`Iterator.from`** uses §7.4 GetIteratorFlattenable (strings allowed; absent `@@iterator` ⇒ use the
  object itself as the iterator). If the iterator already inherits %Iterator.prototype%, returns it
  as-is; otherwise wraps it in a `wrap` helper.

## Gates
build / test / lint / **Iterator ↑** / language no-regression / bench perf:ok.

## Result
Iterator 364→644/1028 (35.4%→62.6%); +280. Verified map/filter/take/drop/flatMap, `Iterator.from`, and
chaining (`.map().filter().take().toArray()`). No regression: language 87.4%, bench perf:ok.

## Deferred
`%Iterator.prototype%[Symbol.toStringTag]` + `constructor` accessors, the helper objects'
`[Symbol.toStringTag]` ("Iterator Helper"), and assorted argument-order / closing edge cases (the
remaining ~384 failures, plus per-helper `.length`/`.name` metadata).
