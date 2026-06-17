# M52 — Number.prototype.toString(radix) non-finite values

## Goal
Fix `Number.prototype.toString(radix)` for NaN / ±Infinity, raising `built-ins/Number` from 63.2%.

## Diagnosis
Radix conversion (`numberToRadixString`) worked for finite values but mishandled non-finite ones:
`NaN.toString(19)` → `""`, `Infinity.toString(2)` → a long run of `0`s. The §21.1.3.6 result for a
non-finite value is radix-INDEPENDENT (`"NaN"` / `"Infinity"` / `"-Infinity"`) — the digit-conversion
algorithm only applies to finite numbers. ~144 `prototype/toString` tests exercise NaN/Infinity across
radixes 2–36, so nearly all failed.

## Fix
One line in `numberMethod`: route NaN and ±Infinity (like radix 10) through the base-10 `toString`,
which already yields the correct spec strings, instead of into `numberToRadixString`.

## Gates
build / test / lint / **Number ↑** / language no-regression / bench perf:ok.

## Result
Number 430→498/680 (63.2%→73.2%); +68. No regression: language 87.4%, bench perf:ok (a transient
str_build spike on the first run cleared on re-run — the change cannot affect string benchmarks).
