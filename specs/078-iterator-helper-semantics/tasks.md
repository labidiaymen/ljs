# M76 — Tasks

- [x] Baseline Iterator (648/1028) + Symbol (124/192); histogram failure clusters.
- [x] `nativeLength`: add iterator helper / ctor / from / helper-next length entries.
- [x] `HelperState.running` flag.
- [x] `closeIteratorNormal` propagating IteratorClose (normal completion).
- [x] Route helper `return()` + `take` exhaustion through `closeIteratorNormal`.
- [x] `helperNext` reentrancy (`running`) guard.
- [x] `iteratorHelper` / `iteratorLimitHelper`: validate callback/limit BEFORE reading `next`.
- [x] `Symbol` constructor: ToString(description) via `toStringThrowing`.
- [x] Gate: zig build / test / lint green.
- [x] Gate: bench perf:ok.
- [x] Gate: language no-regression vs baseline.
- [x] Gate: built-ins no-regression vs baseline.
- [x] Re-measure: Iterator 758/1028 (+110), Symbol 128/192 (+4).
