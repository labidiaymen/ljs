# M36 — BigInt (§21.2 / §6.1.6.2)

A new primitive type. Backed by Zig's arbitrary-precision integer
(`std.math.big.int.Const`/`Managed`), allocated in the realm arena. A `bigint` variant is added to
the `Value` union holding `*const std.math.big.int.Const` (limbs slice owned by the arena).

## Scope landed

1. **Literals (§12.9.3.2).** `123n`, `0x1Fn`, `0o17n`, `0b1010n` — a `BigIntLiteralSuffix` `n` after
   an *integer* literal. The lexer consumes a trailing `n` and tags the token (`is_bigint`). The
   parser builds a `bigint` AST node, parsing the digits at the correct radix (2/8/10/16) into a big
   int. `1.5n` / `1e2n` / `08n` (fraction / exponent / legacy-octal) → SyntaxError (the lexer rejects
   `n` after a `.`/`e`/`E` or a `0`-led NonOctalDecimal).

2. **`typeof` → `"bigint"`** (§13.5.3). `ToBoolean(0n)` = false, else true. `SameValue` /
   `SameValueZero` compare bigints by numeric value. Strict `===` is true iff both are bigint with the
   same value. Loose `==` compares BigInt with Number / String numerically (cross-type).

3. **Operators (§13.x ApplyStringOrNumericBinaryOperator, BigInt::* §6.1.6.2).** When BOTH operands
   are BigInt: `+ - * **` (`**` negative exponent → RangeError), `/ %` (÷0n → RangeError), bitwise
   `& | ^`, shifts `<< >>` (`>>>` for BigInt → TypeError), unary `-` and `~` (unary `+` on a BigInt →
   TypeError). **Mixing BigInt and Number in an arithmetic / bitwise op → TypeError** (§13.15.3); but
   relational `< > <= >=` and `==` DO compare cross-type numerically, and `+` with a String
   concatenates via ToString. Division / remainder truncate toward zero (Zig `divTrunc`; `%` follows
   the dividend's sign).

4. **`BigInt(x)`** (§21.2.1.1): callable, NOT a constructor (`new BigInt` → TypeError). Number→BigInt
   (must be an integer; non-integer or non-finite → RangeError), String→`StringToBigInt`
   (`BigInt("0x1F")` etc; invalid → SyntaxError), Boolean→0n/1n, BigInt→itself. `BigInt.prototype`
   with `.constructor`, `toString([radix])`, `valueOf`. `BigInt.asIntN(bits, x)` / `asUintN(bits, x)`.

5. **ToString(bigint)** for `${}` / `String()` / `+`-with-string: decimal digits, leading `-` for
   negatives. `BigInt.prototype.toString(radix)` supports radix 2..36.

## Deferred (noted)

- `BigInt64Array` / `BigUint64Array` TypedArrays (no TypedArray subsystem yet).
- `JSON.stringify(1n)` → TypeError (no dedicated bigint branch; JSON is itself minimal).
- `Number ↔ BigInt` loose-equality edge cases involving NaN/Infinity are handled (always unequal),
  but full §7.2.15 numeric-tower fidelity for non-integer Number vs BigInt is approximate (compares
  exact integer value of the BigInt vs the Number's f64; safe for integral Numbers).
- BigInt as a property key (`obj[1n]`) coerces via ToString like any primitive key (no special slot).

## Design

- `src/bigint.zig` — a thin module wrapping `std.math.big.int.Managed`, exposing arena-allocating
  constructors (`fromI64`, `fromString`, `fromF64`) and the JS-semantic binary/unary ops returning a
  `*const Const` (or an error tag for RangeError/divide-by-zero). All limbs live in the arena.
- `Value.bigint: *const std.math.big.int.Const`. `writeDisplay` / `ops.toString` print decimal.
- Hot paths (`toNumber`/`toBoolean`/`evalBinary` Number fast path) are untouched: the bigint branch is
  only entered when an operand's tag is `.bigint`.
