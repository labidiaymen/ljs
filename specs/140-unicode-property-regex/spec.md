# Spec 140 — Unicode property escapes in RegExp (`\p{…}` / `\P{…})`

Status: **In progress (cycle 1)**

## Problem / Motivation
ljs's regex engine rejects `\p{Name}` / `\P{Name}` Unicode property escapes (§22.2.1
CharacterClassEscape, the `p`/`P` forms) with `InvalidEscape`. This is the **#1 shared blocker**
for the modern npm ecosystem:
- **webpack** — `RuntimeTemplate.js` uses `/^[_\p{L}][_0-9\p{L}]*$/iu` to validate identifiers.
- **yargs** → string-width — `/^\p{Default_Ignorable_Code_Point}$/u`.
- A whole Test262 category (`built-ins/RegExp/property-escapes/**`) is currently failing.

## Governing spec
- §22.2.1 `CharacterClassEscape :: p{ UnicodePropertyValueExpression } | P{ … }` (UnicodeMode only).
- §22.2.1.1 UnicodeMatchProperty / UnicodeMatchPropertyValue — property name + value resolution.
- The escape is valid ONLY with the `u` (or `v`) flag; without it, `\p` is `p` (Annex B) — already
  handled by the existing escape path, must not regress.

## Scope
**IN (this epic):**
- Lex + parse `\p{Name}` / `\P{Name}` and `\p{Name=Value}` in `/u` mode, both standalone and INSIDE a
  character class (`[_\p{L}]` — webpack needs this).
- Code-point-aware matching for property classes — decode the code point at the match position
  (WTF-8), test membership, advance by the code-point byte length. **Isolated** from the existing
  byte-based `[a-z]`/`\d`/`.` matching (no regression to those).
- A curated property→code-point-ranges table: General_Category (top-level `L N P S Z C M` + the
  common subcategories `Lu Ll Lt Lm Lo Nd Nl No …`), plus the high-value binary properties
  (`White_Space`, `Alphabetic`, `Default_Ignorable_Code_Point`, `ASCII`, `Any`, `Assigned`).
- `\P{…}` negation; `\p{…}` inside a negated class `[^\p{L}]`.

**OUT (later / deferred):**
- Full Unicode script coverage (`Script=Greek`, `Script_Extensions`) and the long tail of binary
  properties — added incrementally in later cycles as packages/Test262 demand.
- `v`-mode set operations (`[\p{L}--\p{Lu}]`).
- Property name loose-matching (we accept the canonical + common alias names only).

## Success criteria
- `/\p{L}/u.test('a') === true`, `/\p{L}/u.test('1') === false`; `/[_\p{L}]/u.test('_')` /
  `.test('x')` true, `.test('9')` false; `\P{…}` negation correct.
- **webpack** parses RuntimeTemplate.js + gets deeper into the build; **string-width** loads.
- Test262 `language` — **no regression**. Test262 `built-ins/RegExp/property-escapes` — measurable
  gain (the common-property tests pass).
- No regression to existing byte-based class/`.`/`\d` matching (the whole RegExp suite holds).

## Cycle plan (≈4 cycles)
1. **(this cycle)** Lex-accept + parse `\p{…}`/`\P{…}` (standalone + in-class) → a property node;
   code-point-aware matcher; starter property table (General_Category + key binaries). webpack
   parses RuntimeTemplate.js.
2. Expand the property table (subcategories + more binaries) + alias names; broaden Test262 pass.
3. Scripts (`Script=…`) + `Name=Value` general resolution.
4. Edge cases: case-insensitive (`i`+`u`) folding interactions, `\P` inside negated class, Test262
   property-escapes tail; finalize.
