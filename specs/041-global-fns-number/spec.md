# M41 — Global functions (§19.2) + Number.prototype methods (§21.1.3)

## Goal
Implement the §19.2 global function intrinsics (all currently 0%) and complete the
§21.1.3 Number.prototype method surface (currently 46.2%), as clean spec algorithms.
Scope is 100% ECMAScript; no host APIs.

## Part A — global functions (§19.2)
Installed on the global Environment (so they are ordinary identifiers) — which the
`builtins.setup` globalThis-mirror loop then exposes as non-enumerable, writable,
configurable own properties of the global object (so `globalThis.parseInt === parseInt`).

- **`isNaN(x)`** (§19.2.3): `let num = ToNumber(x); return num is NaN`. COERCES — unlike
  `Number.isNaN`. `isNaN('foo')` → `true`, `isNaN('3')` → `false`.
- **`isFinite(x)`** (§19.2.2): `let num = ToNumber(x); return num is not NaN/+Inf/-Inf`.
  COERCES. `isFinite('3')` → `true`.
- **`parseInt(string, radix)`** (§19.2.5):
  1. `S = TrimString(ToString(string), start)` — trim leading StrWhiteSpace.
  2. optional leading `+`/`-` sign.
  3. `R = ToInt32(radix)`. If R != 0: if R<2 or R>36 → NaN; if R==16 allow stripping a
     leading `0x`/`0X`. If R == 0: R = 10, but if the (post-sign) text starts `0x`/`0X`
     strip it and set R = 16.
  4. parse the longest prefix of digits valid for R (`0-9`, `a-z`/`A-Z` for 10..35).
  5. empty digit run → NaN; else signed mathematical value as an f64.
- **`parseFloat(string)`** (§19.2.4): `ToString`, trim leading whitespace, parse the
  longest leading StrDecimalLiteral prefix (optional sign, digits, `.`, fractional
  digits, exponent `e`/`E`, or the literal `Infinity`). No valid prefix → NaN.
  `parseFloat('3.14abc')` → 3.14; `parseFloat('Infinity')` → +Inf.
- **URI handlers** (§19.2.6) — percent-encoding over the UTF-8 bytes of the string:
  - `encodeURI(uri)`: preserve `uriUnescaped ∪ uriReserved ∪ '#'`, i.e.
    alnum + `- _ . ! ~ * ' ( )` + `; / ? : @ & = + $ , #`. Everything else → `%XX`
    (uppercase hex) per UTF-8 byte.
  - `encodeURIComponent(c)`: preserve only `uriUnescaped` = alnum + `- _ . ! ~ * ' ( )`.
  - `decodeURIComponent(c)`: every `%XX` → byte; reassemble UTF-8; malformed `%` seq or
    invalid UTF-8 → URIError. `reservedSet` is empty (decode everything).
  - `decodeURI(uri)`: like decode, but a `%XX` whose decoded code point is in
    `uriReserved ∪ '#'` is LEFT as the literal escape (so a round-trip with encodeURI is
    stable). The reserved set here = `; / ? : @ & = + $ , #`.

  Encoding uses the surrogate check: a lone surrogate code point (D800..DFFF) in the
  source → URIError (our source is WTF-8/UTF-8 bytes; we validate UTF-8 on decode and
  reject overlong/lone-surrogate byte forms there).

## Part B — Number.prototype methods (§21.1.3)
`thisNumberValue(this)`: a Number primitive `this`, or a `new Number(x)` wrapper unboxed
via its primitive slot (M22/M29); else TypeError.

- `toString([radix])` — radix 2..36, default 10. radix 10 → Number::toString. For
  2..36 (≠10): sign, integer part by repeated div/mod, then up to a bounded number of
  fractional digits. RangeError if radix < 2 or > 36.
- `toLocaleString` — ≈ `toString()` for the M-subset (no locale/ICU). Noted as a subset.
- `valueOf` — return the unboxed Number.
- `toFixed(digits)` — digits 0..100 (RangeError otherwise); fixed-point decimal. NaN →
  "NaN"; |x| ≥ 1e21 → ToString(x).
- `toExponential(digits)` — exponential notation, `d.dddde±XX`; digits undefined → as
  many as needed; 0..100 else RangeError.
- `toPrecision(precision)` — precision undefined → ToString; else 1..100 significant
  digits (RangeError otherwise), choosing fixed vs exponential per the exponent.

## Out of scope / noted edges
- `toLocaleString` is locale-unaware (returns the `toString()` form) — Test262's
  intl402 cases are not in the default tree.
- Number.prototype radix-toString fractional digits are emitted to a fixed precision
  bound (no infinite expansion); matches V8 for the Test262 corpus.

## Approach
- New `NativeId`s: `global_fn` (one id; `native_name` selects isNaN/isFinite/parseInt/
  parseFloat/encodeURI/encodeURIComponent/decodeURI/decodeURIComponent). `number_method`
  already exists — extend its handler to the full method set.
- Helpers in `interpreter.zig`: `globalFn` dispatch; number-formatting helpers for
  toFixed/toExponential/toPrecision and radix toString.
- Install in `builtins.setup` before the globalThis mirror loop.
