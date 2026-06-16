# M24 — Numeric literals: radix prefixes, separators, exponents (§12.9.3)

**Status:** DONE — `language/` 68.1% → 68.8% (+310; 1 documented unmask). 332 failing files used
non-decimal numeric literals; the scanner only handled decimal.

## What
- Lexer scans `0x`/`0X`, `0o`/`0O`, `0b`/`0B` radix literals, decimal with fraction + **exponent**
  (`1.5e-3` — previously unsupported), and `_` **NumericLiteralSeparators**. §12.9.3 trailing rule
  (no IdentifierStart/digit/`\` immediately after a number → SyntaxError, e.g. `3in1`).
- Parser `parseNumericLiteral`: strips `_`, decodes radix digit-by-digit into f64 (no u64 overflow),
  else `parseFloat`.
- §12.9.3 separator-placement validation (`validNumericSeparators`): each `_` must sit between two
  radix digits; none in LegacyOctal/NonOctalDecimal (`0_7`, `08`). §12.9.3.1 strict-mode Early Error
  for legacy-octal / non-octal-decimal (`08`, `010`).

## Deferred
- **BigInt** (`123n`) — needs a BigInt primitive type (the `n` suffix is not consumed; `123n` stays a
  SyntaxError).
- Legacy-octal VALUE is computed as decimal (a documented M-subset deviation; legacy octal is a
  strict-mode error anyway).
- The 1 unmasked regression (`literals/numeric/7.8.3-3gs#strict`) needs direct `eval` to inherit the
  caller's strict mode (M15-deferred) so the eval'd `01` is rejected; it passed before only because
  the adjacent `0x1` was an *unsupported* parse error.
