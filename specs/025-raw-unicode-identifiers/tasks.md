# M25 tasks — raw Unicode identifiers + Unicode trivia

- [x] T1 `skipTrivia`: decode `>= 0x80` UTF-8; skip §12.2 WhiteSpace (NBSP, U+1680, U+2000–U+200A,
      U+202F, U+205F, U+3000, U+FEFF); treat U+2028/U+2029 as §12.3 LineTerminators (set saw_newline).
      Do NOT skip ZWNJ/ZWJ.
- [x] T2 Helper `rawIdStartLen(pos)`: decode the UTF-8 sequence at `pos`; return its byte length iff
      `>= 0x80` and `isIdStart(cp)`, else 0. Used by the two start-detection call sites.
- [x] T3 `scanIdentifier` fast path: extend the greedy ASCII scan so a `>= 0x80` byte triggers the
      buffered path (rather than ending the identifier) — keeps pure-ASCII identifiers on the alias
      fast path, untouched.
- [x] T4 `scanIdentifier` buffered path: accept raw multibyte ID_Start (first) / ID_Continue (parts)
      by decoding `utf8Decode`; append the raw bytes; an invalid/disallowed cp ends the identifier.
- [x] T5 `scanToken` normal-identifier dispatch: add `or rawIdStart(c)`.
- [x] T6 `scanToken` private-name `#`: detect a raw ID_Start after `#` (alongside ASCII + `\u`).
- [x] T7 Tests in `src/engine.zig`: raw `café`, raw/escape equivalence, raw `#℘` private, `o.℘` round
      trip with `o["℘"]`, raw NBSP as whitespace between tokens, U+2028 as a line terminator.
- [x] T8 Gates: build / test / lint / conformance (≥30056, 0 regressions, update baseline) / bench.
