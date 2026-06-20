# Spec 094 — Lexer: VT (U+000B) + FF (U+000C) are WhiteSpace (§12.2)

Status: Done — language 41,958 → 42,082 (+124), 94.3% → 94.6%, 0 regressions, 0 panics, bench ok.
Owner: Aymen

## Problem
The lexer's trivia-skip recognized ASCII space / TAB / CR / LF but NOT VT (U+000B) or FF (U+000C),
which are §12.2 WhiteSpace. Source with VT/FF between tokens (e.g. `x<VT>+=<VT>1`) failed to tokenize
→ parse_error. The `*-whitespace` Test262 cases exercise every WhiteSpace code point around every
operator, so this single gap failed ~124 cases across compound-assignment, logical-assignment,
exponentiation, prefix/postfix inc/dec, relational/equality/bitwise/additive/multiplicative operators,
and more.

## Fix
`lexer.zig` trivia skip: add `c == 0x0B or c == 0x0C` to the ASCII white-space branch. VT/FF are white
space, NOT line terminators, so they do not set `saw_newline` (no ASI). (Non-ASCII WhiteSpace —
NBSP, the Zs set, ZWNBSP — and LS/PS were already handled.)

## Out of scope
- The non-whitespace `compound-assignment-operator-calls-putvalue-lref` failures (a strict-mode
  PutValue-after-delete edge) — a separate cause.
