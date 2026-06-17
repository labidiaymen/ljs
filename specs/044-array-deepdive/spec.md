# M44 — Array deep-dive

## Goal
Raise `built-ins/Array` conformance from the M43 baseline (38.4%, 2350/6115) by fixing the
highest-impact failure clusters, with **zero** within-Array regressions and no `language/` regression.

## Diagnosis (per-method failure counts, M43 baseline)
Per-subdir runs of the runner (`--path .../Array/prototype/<m>`):

| cluster | methods | ~failures | conformance | root cause |
|---|---|---|---|---|
| **generic-this** | reduceRight, reduce, filter, map, some, every, forEach, indexOf, lastIndexOf | ~2486 | 24–41% | entry guard rejected any non-array `this`; spec methods are *generic* over array-likes (`ToObject` + `LengthOfArrayLike` + `Get`/`HasProperty`) |
| change-by-copy | with, toSorted, toReversed, toSpliced | ~170 | ~5% | generic array-like reading + ES2023 semantics |
| static fromAsync | Array.fromAsync | 186 | 0% | not implemented (out of scope — needs no host, but large async surface; deferred) |
| Symbol.unscopables / species | — | 16 | 0% | metadata gaps |
| join/toString/at/slice/concat/fill/reverse/copyWithin | — | misc | varies | also generic per spec |

## Scope of this milestone (the clusters fixed)
1. **Generic `this` for the read/iterate/accessor family.** Make these methods operate on any
   array-like (`§7.1.18 ToObject`, `§7.3.18 LengthOfArrayLike`, `§7.3.2/§7.3.12 Get/HasProperty`,
   `§7.3.4 Set`): `forEach, map, filter, some, every, find, findIndex, findLast, findLastIndex,
   flatMap, reduce, reduceRight, indexOf, lastIndexOf, includes, join, toString, toLocaleString,
   at, slice, concat, flat, fill, reverse, copyWithin, sort, with, toSorted, toReversed, toSpliced`.
   An `ArrayLike` view (fast path for the array exotic; generic [[Get]]/[[Set]] path otherwise)
   backs every index access, length read, and write so each method stays one code path.
2. **ES2023 change-array-by-copy** (`with`, `toReversed`, `toSorted`, `toSpliced`): return a NEW
   dense Array, read source via Get (sees inherited/getter values), never preserve holes.
3. **`Array.prototype[Symbol.unscopables]`** — a null-proto data object listing the newer methods.

`Array.fromAsync` is explicitly deferred (large, isolated; not the biggest unlock per effort).

## Invariants preserved
- Array exotic fast path unchanged for the common `this`-is-an-array case (no perf regression).
- Throw=true writes still reject frozen / non-extensible targets (CreateDataPropertyOrThrow / Set).
- `language/` baseline untouched; `built-ins/Array` passed strictly increases.
