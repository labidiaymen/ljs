---
description: "Task list for M12 — string-literal escape sequences (§12.9.4.1 hex/unicode/braced-unicode/legacy-octal/line-continuation in the lexer; strict-octal rejection at parse; template decoder unified)"
---

# Tasks: M12 — String-literal escape sequences

**Metric:** conformance reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`), same as M4–M11. PRIMARY gate is the FULL `language/` tree;
`language/expressions` is the continuity floor (≥ 8,256). Baseline (M11 close): full `language/`
**passed 16,427 / 37.6%**.

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + **bench (ljs ≤ Node)**
green). Re-measure the FULL `language/` tree each cycle (primary) + the `language/expressions` continuity.

**Mandatory regression hunt (every cycle):** complete escape decoding is pervasive — most recoveries are
string/class/literals tests whose expected value was previously mis-decoded. The strict-octal rejection
is the only over-rejection risk. `--update-baseline` BEFORE + rebuild ReleaseFast + measure BEFORE vs
AFTER on the FULL `language/` tree, sort + `comm`; true regressions 0 or far outweighed by recoveries.
Verify sloppy octal strings still decode (only strict ones rejected).

## Cycle 1 — complete §12.9.4.1 escape decoding 🎯 (DONE)

**Result (full `language/` tree, harness): passed 16,427 → 16,609 (+182), 37.6% → 38.0%
(skipped unchanged at 809, so no denominator shift).** Regression hunt by `path#mode`
(BEFORE vs AFTER ReleaseFast `comm`): **184 recoveries / 2 TRUE regressions (92:1).** The 2
regressions are the single `expressions/tagged-template/invalid-escape-sequences.js` (strict +
sloppy) — a §12.9.6 case where a TAGGED template with an invalid escape must have `cooked =
undefined` (NOT a SyntaxError). It was passing before only by ACCIDENT (the old `parseTemplate`
decoded all escapes leniently and never errored); ljs models no per-quasi cooked-undefined, so it is
DEFERRED. Choosing the spec-correct UNtagged behavior (invalid template escape → SyntaxError) recovers
24 `expressions/template-literal/invalid-*` tests, far outweighing the 2. Recoveries break down as:
`literals/string` (78 — hex/unicode/octal/line-continuation now decode + raw-LF/CR string rejection),
`expressions/template-literal` (28), `statements`/`expressions/class` computed + accessor PropertyNames
(40), `expressions/object` keys (10), `line-terminators`/`white-space` string-literal tests (~28).
Continuity `language/expressions`: 8,256 → 8,320 (+64). Bench: `perf: ok (no ljs-vs-self regression)`,
ljs 0.2–0.5× Node — escape decoding is lexer-time only, the eval hot path is untouched (`str_build` is
runtime concat, -0.3% vs baseline; an earlier +49.5% reading was pure CPU contention from a concurrent
conformance run, not reproducible clean).

- [x] M12-T010 **Lexer — `Token.has_legacy_octal` flag (`src/lexer.zig`)** — a per-token `bool`
  (default false) set when a string literal contains a LegacyOctalEscapeSequence / NonOctalDecimalEscape
  (`\8`/`\9`) / `\0`-before-a-digit; threaded so the parser can reject in strict mode.
- [x] M12-T020 **Lexer — complete escape decoder (`src/lexer.zig`)** — rewrite `lexString`'s escape
  handling to the full §12.9.4.1 set: Character (`\n\t\r\b\f\v` + quotes/backslash), Hex `\xHH` (invalid →
  LexError), Unicode `\uHHHH` + braced `\u{H…}` (≤0x10FFFF; invalid → LexError; UTF-8 via
  `std.unicode.utf8Encode`, surrogates hand-encoded 3-byte), LineContinuation (LF/CR/CRLF/U+2028/U+2029 →
  nothing), IdentityEscape fallthrough, legacy octal + `\8`/`\9` (sloppy decode + set the flag), `\0` NUL.
  Extract a shared `decodeEscapesInto(buf, src, template)` helper.
- [x] M12-T030 **Parser — strict legacy-octal rejection + template decoder unify (`src/parser.zig`)** —
  reject a `has_legacy_octal` `.string` token in PrimaryExpression + PropertyName positions when
  `self.strict` (`ParseError.UnexpectedToken`); `parseTemplate` calls the shared lexer decoder
  (`lex.Lexer.decodeEscapesInto`, `is_template = true`) per quasi (Hex/Unicode/Character + line
  continuation + `\0`), no octal flag for templates. An invalid template escape is a SyntaxError (the
  §12.9.6 untagged behavior); tagged-template `cooked = undefined` deferred.
- [x] M12-T040 **Tests (`src/engine.zig`, all green)** — `"\x41" === "A"`; `"B" === "B"`;
  `"\u{1F600}".length` == 4 (UTF-8 byte length, documented); `"\101" === "A"` (sloppy octal); `"a\<LF>b"
  === "ab"` + CRLF (line continuation); `"\0".charCodeAt(0) === 0`; `\b`/`\f`/`\v` charCodes;
  computed key `o["\x41"]=5; o.A === 5`; strict-octal `"\101"`/`"\1"`/`'\8'` → SyntaxError; `"\0"` legal
  strict; invalid `"\xZZ"`/`"\x4"`/`"\u{110000}"`/`"\u123"`/`"\u{}"` → SyntaxError; identity `"\q" ===
  "q"`; template `` `\x41` === "A" `` / `` `\u{41}` === "A" ``.
- [x] **Conformance + regression hunt (harness, ReleaseFast, BEFORE vs AFTER `comm`):** full `language/`
  `passed 16,427 → 16,609 (+182, ≥ 16,427)`; 184 recoveries / 2 true regressions (the documented
  tagged-template deferral); `language/expressions 8,256 → 8,320 (≥ 8,256)`. Bench green.
- [x] **Landed:** the complete §12.9.4.1 string-literal escape set — Character (`\n\t\r\b\f\v` + quotes/
  backslash/identity), Hex `\xHH`, Unicode `\uHHHH` + braced `\u{H…}` (UTF-8-encoded, lone surrogates
  hand-encoded), LineContinuation (LF/CR/CRLF/U+2028/U+2029), legacy octal + `\8`/`\9` (sloppy) with a
  strict-mode Early Error via the `has_legacy_octal` token flag + `\0` NUL; unified template decoder
  (Hex/Unicode/Character/line-continuation/`\0`). **Deferred:** tagged-template `cooked = undefined` for
  an invalid escape (§12.9.6 — needs per-quasi cooked modeling; costs 1 test, recovers 24 untagged);
  UTF-16 code-unit `String.length` / surrogate-pair indexing (ljs strings are UTF-8 byte slices —
  `.length` is byte length); IdentifierName `\uHHHH` escapes (§12.7.1, separate lexer path).
