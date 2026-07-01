# Tasks: Math completion

## Phase 1

- [x] T1 `Math.floor`/`ceil`/`round`/`trunc` -- `number -> int`.
- [x] T2 `Math.pow(base, exp)` -- `(number, number) -> number`, same-type
  requirement as `max`/`min`.
- [x] T3 `Math.log`/`sin`/`cos` -- `number -> number`.
- [x] T4 `Math.PI()` -- zero-arg function.
- [x] T5 Found and fixed a real, pre-existing bug while testing: whole-
  number float literals (`4.0`) lower to a bare numeral with no decimal
  point, which Zig's math builtins (`@floor`, `@sqrt`, `@abs`, etc.,
  unlike a normal function-parameter context) don't auto-coerce from
  `comptime_int`. Fixed every affected function, including the
  pre-existing `sqrt`/`abs` (not just the new ones), to force the float
  type explicitly.
- [x] T6 Verified: `floor(3.7)=3`, `ceil(3.2)=4`, `round(3.5)=4`,
  `trunc(-3.7)=-3`, `pow(2.0,10.0)=1024`, `pow(2,3)=8`, `log(1.0)=0`,
  `sin(0.0)=0`, `cos(0.0)=1`, `PI()=3.141592653589793`. Separately
  confirmed the whole-number-literal fix with `abs(-4.0)=4` and
  `sqrt(4.0)=2` (previously would have failed to compile).
- [x] T7 `zig build test` passes. `zig build conformance` run clean.
- [x] T8 Update `website/stdlib.html`'s existing Math section (not a new
  section) with the five new rows; remove the Planned-table row's Math
  half, keeping only the `push`/`pop`/`sort` (growable-array) part.
- [x] T9 Commit, push, redeploy `lumen-playground`.
