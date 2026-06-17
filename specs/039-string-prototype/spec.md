# M39 — String.prototype standard-library methods (§22.1.3)

## Goal
Land the clean (non-RegExp) `String.prototype` method family plus the `String` statics, to lift
`built-ins/String` conformance well above the M2 baseline (494/2443 = 20.2%). No RegExp engine is
in scope this cycle, so the regex forms of `match`/`matchAll`/`replace`/`replaceAll`/`search`/`split`
are deferred; only the **string-argument** paths of `replace`/`replaceAll` are implemented.

## Scope — methods landed

### `String.prototype` (§22.1.3) — added on top of M2 (charAt/charCodeAt/indexOf/includes/slice/substring/toUpperCase/toLowerCase/split/toString/valueOf)
- `at(index)` — §22.1.3.1: relative index (negative from end), byte-based; out of range → undefined.
- `codePointAt(pos)` — §22.1.3.4: UTF-8 decode the code point starting at byte `pos`; out of range → undefined.
- `concat(...args)` — §22.1.3.5: ToString each arg and append.
- `endsWith(search[, endPos])` — §22.1.3.7.
- `startsWith(search[, pos])` — §22.1.3.24.
- `includes` — already M2; kept (now honors a `position` 2nd arg).
- `indexOf([, pos])` / `lastIndexOf([, pos])` — §22.1.3.9/.11 (position arg honored; lastIndexOf added).
- `padStart(maxLen[, filler])` / `padEnd(maxLen[, filler])` — §22.1.3.16/.15 (byte-length based).
- `repeat(count)` — §22.1.3.18: RangeError on negative / non-finite count.
- `trim` / `trimStart` / `trimEnd` — §22.1.3.32/.34/.33: strip leading/trailing WhiteSpace + LineTerminators.
- `substr(start, length)` — Annex B §B.2.2.1.
- `localeCompare(that)` — §22.1.3.10: **simple code-unit (byte) compare** for the M-subset
  (no ICU/CLDR collation). Returns -1 / 0 / +1. Noted deviation.
- `at`/`codePointAt` honor the byte model (documented `.length`/indexing deviation).

### `String` statics (§22.1.2)
- `String.fromCharCode(...codeUnits)` — §22.1.2.1: each arg → ToUint16, UTF-8-encode the code unit value.
- `String.fromCodePoint(...codePoints)` — §22.1.2.2: each arg must be an integer in [0, 0x10FFFF]
  (else RangeError), UTF-8-encode.
- `String.raw(template, ...subs)` — §22.1.2.4: reads `template.raw`, ToString each segment, interleaves
  substitutions. Works when called **directly** (the spec's real definition operates on a template
  object's `raw` array). Tagged-template syntax is not wired (the parser has no tagged-template node),
  so the `` String.raw`...` `` syntactic form is N/A — but every direct-call test passes.

## Deferred (need a RegExp engine — out of scope this cycle)
- `match`, `matchAll`, `search` (always need RegExp).
- `replace` / `replaceAll` with a RegExp first arg, and `$`-pattern substitution semantics beyond the
  plain `$$`/`$&`/`` $` ``/`$'` set — the **string-search** form IS implemented (with the standard
  `$` replacement-pattern handling for the string path).
- `split` with a RegExp separator (string separator already works from M2).
- `normalize` — Unicode normalization (NFC/NFD/NFKC/NFKD) needs the UCD; deferred. (ASCII is already
  normalized, but the conformance tests exercise real combining sequences, so a no-op would mislead —
  left unimplemented rather than faked.)
- `isWellFormed` / `toWellFormed`, `toLocaleLowerCase` / `toLocaleUpperCase` — not in the requested set.

## Model
UTF-8 byte strings (engine-wide documented deviation): `.length` and indexing are byte-based. The
methods operate consistently on bytes. `codePointAt` / `fromCodePoint` decode/encode UTF-8 code points;
`fromCharCode` encodes a 16-bit code-unit value as its UTF-8 code point (lone surrogates are encoded as
their WTF-8-style 3-byte form so round-trips through the byte store are stable).

## Dispatch
- Prototype methods reuse the existing `string_method` `NativeId` → `builtin_string.call`.
- Statics use a new `string_static` `NativeId` → `builtin_string.staticCall(it, name, args)`
  (modeled on `array_static`). Registered on the `String` constructor object, non-enumerable.

## Supporting interpreter fixes (needed for 0 within-String regressions)
- §22.1.4.1/§10.4.3 `new String(s)` wrapper exposes `.length` and integer indices [0,len) (getProperty).
- §17/§10.3 built-in methods/statics are non-constructors (`new String.prototype.concat` → TypeError).
- §7.1.4 ToNumber(BigInt) throws a TypeError (toNumberV) — `String.fromCharCode(0n)` propagates it.
- New public `Interpreter.toStringThrowing` (§7.1.17 full form: ToPrimitive + Symbol-throw) backs the
  string library's throwing `this`/argument coercion.

## Done — delta
built-ins/String: 494/2443 (20.2%) → 1402/2443 (57.4%) [+908]. 0 regressions within String;
language/ "conformance: ok (no regression vs baseline)".
