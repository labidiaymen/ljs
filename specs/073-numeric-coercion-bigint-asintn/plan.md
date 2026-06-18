# 073 — Plan

## Files touched (all owned by this agent)
- `src/abstract_ops.zig` — new `stringToNumber` (§7.1.4.1.1) + `strWhiteSpaceAt`,
  `radixDigitsToNumber`, `isStrDecimalLiteral` helpers; `toNumber(.string)` and `strToNumber`
  delegate to it.
- `src/builtins.zig` — `Number.prototype.primitive = .{ .number = 0 }` (§21.1.3 [[NumberData]]).
- `src/builtin_bigint.zig` — `asIntN`/`asUintN` `bits` via `it.toIntegerOrInfinity` + ToIndex
  range check; `toString` radix via `it.toIntegerOrInfinity`. Drop now-unused `ops`/`toNumber`
  imports.
- `src/builtin_number.zig` — collapse `-0 → +0` in `toFixed` / `toExponential`.

## Design calls
- StringToNumber implemented directly (not via `std.fmt.parseFloat`) so the StrNumericLiteral
  grammar is enforced: rejects `_` separators, honors `0x`/`0o`/`0b`, accepts `±Infinity`,
  preserves `-0`. `parseFloat` is still used for the final decimal mantissa once the grammar has
  validated the shape (it accepts a strict superset, so a pre-validated decimal string is safe).
- White-space trimming recognises the multibyte §12.2 StrWhiteSpace code points (NBSP, the
  U+2000.. separators, LS/PS, BOM) over the WTF-8 byte storage, since Test262 exercises them.
- ToIndex/ToInteger reuse the interpreter's existing `toIntegerOrInfinity` (public) rather than a
  local re-implementation, so object ToPrimitive + the BigInt/Symbol TypeError come for free.

## Constitution Check
- Correctness-leads: every change is a 1:1 spec-clause fix; no speculative behavior.
- Perf gate: `stringToNumber` keeps an ASCII / common-case fast path; `zig build bench` shows no
  ljs-vs-self regression. The numeric-coercion path is not a measured hot loop.

## Risk
- `stringToNumber` is reachable from every `Number(string)` / string ToNumber across the suite.
  Mitigated by running the full `language` baseline (44,475 tests) → 0 regressions.

## Deferred (reported, needs forbidden files)
- `Number(BigInt)` → Number (`src/interpreter.zig` `number_ctor`).
- `Object(bigint)` boxing of `[[BigIntData]]` (`src/interpreter.zig` / `builtin_object.zig`).
- Native non-constructor functions exposing `.prototype` (`src/object.zig`).
- Exactly-rounded `toFixed`/`toExponential`/`toPrecision` at high precision (needs a
  Dragon/Ryu fixed-format; Zig std rounds via shortest-form) — 3 Number tests.
