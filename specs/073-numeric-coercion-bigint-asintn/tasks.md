# 073 — Tasks

- [x] Histogram failing clusters across Number/Math/BigInt/global-fns; pick shared root causes.
- [x] `Number.prototype` [[NumberData]] = +0 (`src/builtins.zig`).
- [x] Spec-compliant `stringToNumber` (§7.1.4.1.1) in `src/abstract_ops.zig`; wire `toNumber`/
      `strToNumber` to it (reject `_`, honor 0x/0o/0b, ±Infinity, -0, full StrWhiteSpace trim).
- [x] `BigInt.asIntN`/`asUintN` `bits` → ToIndex via `toIntegerOrInfinity` + range check.
- [x] `BigInt.prototype.toString` radix → `toIntegerOrInfinity` (TypeError on BigInt/Symbol).
- [x] `Number.prototype.toFixed`/`toExponential` collapse -0 → +0.
- [x] Gate: `zig build` / `test` / `lint` green.
- [x] Gate: `built-ins/Number` 500→656, `built-ins/BigInt` 106→122; Math/parseInt/parseFloat/
      isNaN/isFinite unchanged (no regressions).
- [x] Gate: full `language` baseline — 0 regressions (44,475 tests).
- [x] Gate: `zig build bench` — no ljs-vs-self regression.
- [x] Report deferred cross-file items (Number(BigInt), Object(bigint) boxing, native
      `.prototype`, exact high-precision formatting).
