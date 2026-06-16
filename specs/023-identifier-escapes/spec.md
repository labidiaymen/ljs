# M23 — IdentifierName unicode escapes (§12.7.1)

**Status:** DONE — `language/` 64.0% → 68.1% (+1,782, 0 regressions). The single biggest remaining
lever (a prior attempt got the gain but ~150 regressions; this lands clean).

## What
- `\uHHHH` / `\u{H…}` escapes at identifier START and in PARTS, and in private names (`#\u…`), decoded
  (UTF-8) into the identifier's StringValue (used for keyword matching + as the property/binding name).
- Real Unicode **ID_Start / ID_Continue** validation via `src/unicode_id.zig` (BMP range tables): an
  escaped code point not valid in the relevant position is a SyntaxError (e.g. U+2E2F vertical tilde,
  ZWNJ/ZWJ at start). Recovers the `identifiers/*` negatives.
- §12.7.1 ReservedWord rejection (PARSER-level, at Identifier/BindingIdentifier/IdentifierReference
  positions only — so `o.\u{69}f` is a valid property name but `var \u{69}f` is a SyntaxError),
  excepting `yield`/`await` per the §12.7.1 exception.

## Deferred
- Raw (non-escaped) non-ASCII identifier source bytes + the matching Unicode-whitespace handling in
  `skipTrivia` (escapes-only landing avoids the whitespace/line-terminator regressions). Unicode ≥14.0
  additions and a small minority of `identifiers/*` are uncovered (see unicode_id.zig header).
