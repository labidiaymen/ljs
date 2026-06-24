# Tasks — spec 139 cycle 1

- [ ] T1 — Find + fix the lexer site that rejects `\p`/`\P` inside a regex literal (accept; keep raw).
- [ ] T2 — `src/unicode_props.zig`: PropId enum + sorted u21 range tables for General_Category
      (`L Lu Ll Lt Lm Lo M N Nd Nl No P S Z C` …) + binaries (`White_Space Alphabetic
      Default_Ignorable_Code_Point ASCII Any Assigned`); `lookup(name)` + `contains(id, cp)`.
- [ ] T3 — regex engine: parse `\p{Name}` / `\P{Name}` (standalone) → property node.
- [ ] T4 — regex engine: parse `\p{…}` INSIDE `[...]` → class carries property refs.
- [ ] T5 — matcher: code-point-aware path for property-bearing classes (decode cp, test ranges+props,
      advance by utf8 len); preserve the byte fast path for property-free classes.
- [ ] T6 — `\P` negation + `\p` inside a negated class `[^…]`.
- [ ] T7 — micro-tests: `\p{L}`, `\p{N}`, `[_\p{L}]`, `\P{L}`, astral (`\p{L}` on an astral letter).
- [ ] T8 — GATE: `zig build` + `test` + `lint` + `bench`; Test262 language differential (no regress)
      + `built-ins/RegExp/property-escapes` count (gain). Verify webpack parses RuntimeTemplate.js.
- [ ] T9 — re-run the popular-package batch (no regression); commit.
