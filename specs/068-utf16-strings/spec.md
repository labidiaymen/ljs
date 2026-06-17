# Feature Specification: UTF-16 string semantics (EPIC)

**Feature Branch**: `068-utf16-strings` (milestones **M80+**, phased)
**Created**: 2026-06-17
**Status**: Phase 1 done (M80) — language 89.6% (39116, +8, 0 regressions); built-ins/String now measurable (1754/2443). Phases 2-5 pending.

**Input**: User-authorized scope expansion to break past the ~92-93% ceiling. ECMA-262 defines a
String as a sequence of **UTF-16 code units** (§6.1.4). ljs stores `[]const u8` UTF-8 and reports
`length`/`charCodeAt`/indexing over BYTES — `"é".length===2` (should be 1), `"😀".length===4`
(should be 2), `charCodeAt` returns UTF-8 bytes (240/159) instead of surrogates (0xD83D/0xDE00),
`"\uD83D".length===3` (should be 1). This deviation fails a SCATTERED set of tests across many dirs
(anything touching non-ASCII / surrogates / `\u` escapes / code-point iteration / regex).

## Design

Keep the `Value.string: []const u8` storage TYPE (so the value union and all plumbing are
unchanged) but redefine the BYTES as **WTF-8** — UTF-8 generalized to encode lone surrogates
(U+D800..U+DFFF as 3 bytes). Astral chars stay 4-byte UTF-8; a surrogate PAIR in source
(`"😀"`) is stored as the combined 4-byte astral and DECOMPOSED into two code units on
access. Observable UTF-16 quantities (`length`, code-unit indexing, methods, iteration, regex) are
computed on demand from the WTF-8 bytes, with an **ASCII fast path**: a string with no byte ≥ 0x80
has code-unit-length == byte-length and code-unit-index == byte-index (O(1), unchanged perf). Only
non-ASCII strings pay an O(n) decode. A small `string_utf16.zig` module provides the shared helpers
(`isAscii`, `utf16Length`, `codeUnitAt`, `byteRangeForCodeUnits`, WTF-8 encode/decode of a code
point ↔ surrogate decomposition).

## Phases (each a gated, committed milestone)

- **Phase 1 (M80) — char-access family:** `string_utf16.zig` helpers + `String.prototype.length`,
  `charCodeAt`, `charAt`, `at`, `[index]` access, and the for-in char-index boxing — code-unit
  semantics with the ASCII fast path. (`codePointAt` already decodes correctly.)
- **Phase 2 — string literal / escapes:** the lexer's `\u{...}` / `\uXXXX` (incl. lone surrogates
  → WTF-8) and surrogate-pair combining; `String.fromCharCode` (code units → WTF-8),
  `String.fromCodePoint`, `String.raw`.
- **Phase 3 — index-based methods:** `slice`/`substring`/`substr`/`indexOf`/`lastIndexOf`/
  `includes`/`startsWith`/`endsWith`/`split`/`padStart`/`padEnd`/`repeat`/`concat` on code-unit
  indices.
- **Phase 4 — iteration + misc:** `String.prototype[Symbol.iterator]` (code points), `normalize`,
  `localeCompare`/comparison, `JSON.stringify`/`parse` surrogate handling, template literals.
- **Phase 5 — regex:** the regex engine matches on code units (`.`, classes, quantifiers, `u`-flag
  code-point semantics, `\uXXXX`).

## Success Criteria
- **SC-001**: each phase raises `language/` (and `built-ins/String`) conformance with **0
  regressions** vs baseline.
- **SC-002**: `zig build bench` stays "perf: ok" — the ASCII fast path keeps common (ASCII)
  string ops O(1); only non-ASCII pays decode.
- **SC-003**: `"é".length===1`, `"😀".length===2`, `"😀".charCodeAt(0)===0xD83D`,
  `"\uD83D".length===1`, `String.fromCharCode(0x100).charCodeAt(0)===0x100`.
