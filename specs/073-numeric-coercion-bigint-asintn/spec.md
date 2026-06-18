# 073 — Numeric coercion + BigInt ToIndex/ToInteger conformance

## Scope
Highest-leverage failing clusters across `built-ins/Number`, `built-ins/BigInt`, and the
string→number coercion shared by `Number(string)` / `isNaN` / `isFinite`. All fixes live in
files this agent owns: `src/builtin_number.zig`, `src/builtin_bigint.zig`,
`src/abstract_ops.zig`, and the builtin wiring in `src/builtins.zig`.

## Root causes & fixes

1. **`Number.prototype` has no `[[NumberData]]`** (§21.1.3). `Number.prototype.toString()`,
   `.valueOf()`, `.toFixed()`, `.toExponential()`, `.toPrecision()` all threw a TypeError
   ("incompatible receiver") because the prototype object carried no Number primitive. Per
   spec `Number.prototype` is an ordinary object whose `[[NumberData]]` is `+0`. Fix: set
   `Number.prototype.primitive = .{ .number = 0 }` at construction (`src/builtins.zig`).
   Clears ~45 Number tests (the whole `S15.7.4.2_A2_T*` toString-radix family + valueOf/
   toFixed/toExponential/toPrecision prototype cases).

2. **`StringToNumber` (§7.1.4.1.1) used `std.fmt.parseFloat`**, which is not the ECMAScript
   StringNumericLiteral grammar. Consequences: `Number("1_1")` returned `11` (separators must
   be rejected -> `NaN`); `Number("0b10")`/`Number("0o17")` returned `NaN` (binary/octal radix
   prefixes must be honored -> `2`/`15`). Fix: a spec-compliant `stringToNumber` in
   `src/abstract_ops.zig` — trims ECMAScript whitespace, handles empty->0, `Infinity`/`±Infinity`,
   `0x`/`0o`/`0b` radix literals (no sign), and a decimal grammar that rejects `_` separators.
   Used by `toNumber(.string)`, `strToNumber`, and the BigInt-comparison string paths.

3. **`BigInt.asIntN` / `asUintN` `bits` used raw `toNumber`** instead of `ToIndex`
   (§7.1.22 over ToIntegerOrInfinity). Consequences: `asIntN(NaN,…)`/`asIntN({},…)` threw
   instead of treating bits as 0; `asIntN(0n,…)` returned a value instead of the required
   TypeError (ToNumber(BigInt) throws); negatives/>=2^53/±Infinity needed RangeError. Fix:
   route `bits` through `it.toIntegerOrInfinity` then apply ToIndex range checks.

4. **`BigInt.prototype.toString` radix used raw `toNumber`** instead of ToIntegerOrInfinity:
   a BigInt/Symbol radix must throw a TypeError (ToNumber step), and an object radix must be
   ToPrimitive'd. Fix: route radix through `it.toIntegerOrInfinity`, keeping the 2..36
   RangeError.

5. **`Number.prototype.toFixed` / `toExponential` of `-0` emitted a spurious `-`** (Zig's
   `{d}`/`{e}` formatters carry the sign bit). The §21.1.3.2/.3 algorithms prepend `-` only when
   `x < 0`, and `-0 < 0` is false, so `(-0).toFixed(2)` is `"0.00"` and `(-0).toExponential(0)`
   is `"0e+0"`. Fix: collapse `-0 → +0` before formatting in `src/builtin_number.zig`.

## Out of scope (reported, not in this agent's files)
- `Number(10n)` must return `10` — the `number_ctor` branch in `src/interpreter.zig`
  (forbidden) ToNumbers a BigInt and throws; needs a BigInt->Number special-case there. Blocks
  `BigInt/prototype/toString/a-z.js`.
- Native (non-constructor) functions wrongly expose a `.prototype` property — created in
  `src/object.zig`; broad cross-area change, blocks `isNaN/parseInt/...` `*.6` and
  `not-a-constructor` tests. Reported for the owning agent.

## Acceptance (Test262, vendored at the pinned commit)
- `built-ins/Number`, `built-ins/BigInt` pass counts up; `built-ins/Math`,
  `built-ins/parseInt`, `built-ins/parseFloat`, `built-ins/isNaN`, `built-ins/isFinite` no
  regressions.
- `zig build` / `test` / `lint` / `bench` green; language baseline 0 regressions.
