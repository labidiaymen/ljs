# Feature Specification: M12 — String-literal escape sequences (§12.9.4.1)

**Feature Branch**: `013-string-escapes`

**Created**: 2026-06-16

**Status**: Cycle 1 (lexer escape decoding — hex / unicode / braced unicode / legacy octal /
line continuation) — DONE

**Input**: "M12 (lexer/runtime completeness). String-literal escape sequences are NOT decoded
beyond the basics. `"\x41" === "A"` returns `false` (it evaluates to `"x41"` — `\x` is wrongly
treated as the IdentityEscape `x` and `41` survives). Hex `\xNN`, unicode `\uNNNN` and `\u{…}`,
legacy octal, `\8`/`\9`, and line continuations are all unhandled. This is systematic — it breaks
string literals across the whole suite (string tests, class computed/accessor-name tests, etc.).
Implement the FULL §12.9.4.1 escape set in the lexer, UTF-8-encoding code points (the engine uses
`[]const u8` byte strings)."

## Why (data-driven)

At M11 close the full `language/` tree is **passed 16,427 / 37.6%** (harness metric);
`language/expressions` is **8,256 / 47.5%**. The lexer's `lexString` decoder (`src/lexer.zig`)
handled only `\n \t \r \\ \" \'` and fell every other escape through to IdentityEscape (`\c → c`).
So `\x41`, `A`, `\u{1F600}`, and the legacy octal `\101` all decode WRONG — the backslash is
dropped and the following ASCII characters survive verbatim. Any test whose *expected* string is
produced via an escape (a huge fraction of `built-ins/String`, `language/literals/string`,
computed/accessor `PropertyName`s in `language/expressions/class` and `language/statements/class`,
`language/literals/string/legacy-*`, line-continuation tests) silently compares wrong and fails.
This cycle implements the COMPLETE escape grammar in the lexer (and unifies the template-literal
decoder with the shared parts), encoding code points as UTF-8.

## Approach: a complete §12.9.4.1 decoder in `lexString`, UTF-8 output

The lexer decodes a string literal into `string_value` (an arena `[]const u8`). The engine's strings
are UTF-8 byte slices, so a decoded code point is emitted via `std.unicode.utf8Encode`. The complete
`EscapeSequence` grammar:

- **CharacterEscapeSequence (single-char):** `\n`→LF, `\t`→TAB, `\r`→CR, `\b`→BS (0x08), `\f`→FF
  (0x0C), `\v`→VT (0x0B), `\\ \' \" \``→themselves, and `` \` ``/`\$` (template-relevant) →
  themselves. Any other NonEscapeCharacter `\c` → `c` (IdentityEscape, §12.9.4.1).
- **HexEscapeSequence `\xHH`** — exactly 2 hex digits → that code unit (a byte ≤ 0xFF; emitted as
  one UTF-8 byte if ≤ 0x7F, else 2-byte UTF-8). Fewer than 2 hex digits → SyntaxError (LexError).
- **UnicodeEscapeSequence:**
  - `\uHHHH` — exactly 4 hex digits → that code unit, UTF-8-encoded. (A lone surrogate D800–DFFF is
    encoded via WTF-8-style 3-byte form — `utf8Encode` rejects surrogates, so they are emitted by hand.)
  - `\u{H…}` — 1+ hex digits, value ≤ 0x10FFFF → that code point, UTF-8-encoded. > 0x10FFFF, empty
    braces, or a missing `}` → SyntaxError.
- **LineContinuation** — a `\` immediately followed by a LineTerminator (LF, CR, CRLF, U+2028, U+2029)
  produces NOTHING; the line terminator(s) are elided (§12.9.4.1 LineContinuation).
- **LegacyOctalEscapeSequence + NonOctalDecimalEscapeSequence (Annex B.1.2, sloppy only):**
  `\0`–`\377` octal runs (`\1`..`\7`, `\01`..`\77`, `\100`..`\377`) → the code unit; `\8`/`\9` →
  `8`/`9`. In STRICT mode these are a SyntaxError; `\0` NOT followed by a decimal digit is the NUL
  character U+0000 and is LEGAL in both modes.

### Strict-mode octal: a per-token flag the parser rejects

The lexer tokenizes the WHOLE source up front (`parseMode` drains `lexer.next()` into a list) BEFORE
the parser determines strict-ness (RunMode or a `"use strict"` directive prologue). So the lexer
cannot itself decide whether a legacy-octal escape is an early error. Mirroring how other strict
early errors are threaded, the lexer sets a per-token boolean **`Token.has_legacy_octal`** when a
string literal contains a LegacyOctalEscapeSequence / NonOctalDecimalEscape / `\0`-before-a-digit; the
parser, at the point it consumes a `.string` token (PrimaryExpression and PropertyName positions) and
the template path, rejects it with `ParseError.UnexpectedToken` when `self.strict`. Sloppy strings
decode the octal normally. (The directive-prologue scan is unaffected: it already compares the raw
lexeme, and `"use strict"` has no escapes; an octal escape inside a directive string would be in a
prologue that turns the unit strict, and the parser's per-token rejection still fires on that string.)

### Templates (§12.9.6) unified where the spec shares it

`parseTemplate` (`src/parser.zig`) decodes the raw inner text. Templates SHARE the CharacterEscape /
Hex / Unicode escapes with string literals but FORBID LegacyOctal / `\8` / `\9` and add `\0` (NUL).
The shared decoding is extracted into one lexer helper (`decodeEscapesInto`) parameterized by a
`template: bool` flag; `parseTemplate` calls it for each quasi chunk so `` `\x41` `` / `` `A` `` /
`` `\u{41}` `` / line continuations now cook correctly. Template-specific full §12.9.6 invalid-escape
`cooked = undefined` (for tagged templates) is kept simple — an invalid escape in a template is
treated leniently here (decoded as best-effort) rather than producing the `undefined` cooked value;
this is noted as a deferred refinement (untagged templates with invalid escapes are rare and the
common `\x`/`\u` valid cases now work).

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Re-measure the full `language/` tree (PRIMARY) + `language/expressions`
(continuity) and run the mandatory before/after `path#mode` regression hunt. Escapes are pervasive, so
a solid gain is expected; the strict-octal rejection is the only over-rejection risk — verified that
sloppy octal strings still decode and only strict ones are rejected.

### US1 — hex escapes `\xHH` (§12.9.4.1) (P1)
`"\x41" === "A"`; `"\x4A" === "J"`; a computed key `o["\x41"] = 5; o.A === 5`. Invalid (`"\xZZ"`,
`"\x4"`) → SyntaxError. **Test**: covered.

### US2 — unicode escapes `\uHHHH` and `\u{H…}` (§12.9.4.1) (P1)
`"A" === "A"`; `"\u{41}" === "A"`; `"\u{1F600}"` is the 4-byte UTF-8 grinning-face — its `.length`
is the UTF-8 BYTE count the engine uses (documented: ljs `String.length` is byte length, not UTF-16
code units). Invalid (`"\u{110000}"`, `"\u123"`, `"\u{}"`) → SyntaxError. **Test**: covered.

### US3 — single-char + identity escapes (§12.9.4.1) (P1)
`"\b\f\v"` decode to 0x08/0x0C/0x0B; `"\0".charCodeAt(0) === 0` (NUL); `"\q" === "q"` (IdentityEscape).
**Test**: covered.

### US4 — line continuation (§12.9.4.1) (P1)
`"a\<LF>b" === "ab"`; `"a\<CRLF>b" === "ab"` (the `\` + newline produces nothing). **Test**: covered.

### US5 — legacy octal + `\8`/`\9` (Annex B.1.2, sloppy) + strict rejection (P1)
Sloppy: `"\101" === "A"`, `"\7"` is 0x07, `"\0"` is NUL. Strict: a LegacyOctalEscapeSequence
(`"\101"`, `"\1"`, `\0`-before-a-digit) is a SyntaxError. **Test**: covered.

### Edge Cases
- `\0` followed by a digit (`\07`) is a LegacyOctalEscapeSequence (sloppy → octal 07; strict → error),
  whereas `\0` followed by a non-digit / end is the NUL escape (legal in both modes).
- `\xHH` and `\uHHHH` use accept-exactly-N-digits; surplus digits are literal (`"\x414"` → "A4").
- A lone surrogate `\uD800` is emitted as 3-byte WTF-8 (ljs keeps byte strings; `utf8Encode` would
  reject it). Documented; the round-trip via `charCodeAt`/`fromCharCode` is byte-based in ljs.
- A line continuation across CRLF elides BOTH the CR and the LF (one LineTerminatorSequence).

## Requirements *(mandatory)*
- **FR-001** (US1–US5): `Token.has_legacy_octal: bool` (default false), set by the lexer when a string
  literal contains a legacy-octal / NonOctalDecimal / `\0`-before-digit escape.
- **FR-002** (US1–US4): a complete §12.9.4.1 decoder in `src/lexer.zig` — Character/Hex/Unicode/braced-
  Unicode escapes (UTF-8-encoded via `std.unicode.utf8Encode`, surrogates hand-encoded), LineContinuation
  elision, IdentityEscape fallthrough. Invalid hex/unicode → `LexError` (→ SyntaxError at the engine).
- **FR-003** (US5): the same decoder handles legacy octal + `\8`/`\9` in sloppy mode and flags the token;
  the parser rejects a `has_legacy_octal` `.string` token (PrimaryExpression, PropertyName, template) when
  `self.strict` → `ParseError.UnexpectedToken`.
- **FR-004** (templates): `parseTemplate` reuses the shared decoder (Character/Hex/Unicode + line
  continuation + `\0` NUL); octal/`\8`/`\9` are not flagged for templates (template-specific
  `cooked = undefined` deferred).

## Out of scope (this cycle)
- Tagged-template `cooked = undefined` for an invalid escape (§12.9.6) — best-effort decode for now.
- UTF-16 code-unit `String.length` / surrogate-pair indexing semantics — ljs strings are UTF-8 byte
  slices; `.length` is byte length. (A future code-unit-accurate string model is a separate milestone.)
- Identifier `\uHHHH` escapes in IdentifierName (§12.7.1 — a separate lexer path, not string literals).
