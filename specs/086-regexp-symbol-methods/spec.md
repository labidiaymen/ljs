# Spec 086 — RegExp prototype Symbol methods + getter descriptors (§22.2)

**Status:** Done — `built-ins/RegExp` 1688/3756 (44.9%) → 2232/3756 (59.4%), +544, 0 panics.
`language/` 40,565/44,475 passing (≥ 40,450 threshold), 0 panics, no regression. (spec 085 Wave 2)
**Parent:** `specs/085-builtins-to-70/` — RegExp pool (2,088 fails).

## Goal
Recover the large recoverable RegExp clusters in `built-ins/RegExp`:
- `RegExp.prototype[Symbol.match]` (§22.2.6.8)
- `RegExp.prototype[Symbol.matchAll]` (§22.2.6.9) + `%RegExpStringIteratorPrototype%` (§22.2.9)
- `RegExp.prototype[Symbol.replace]` (§22.2.6.11) with `$1 $<name> $& $\` $' $$` substitutions
- `RegExp.prototype[Symbol.search]` (§22.2.6.12)
- `RegExp.prototype[Symbol.split]` (§22.2.6.14)
- `RegExpExec` abstraction (§22.2.7.1) — honor an overridden `exec` property.
- `d` flag match `indices` array + named `indices.groups` (§22.2.7.2 step 34, MakeMatchIndicesIndexPairArray).
- Getter `length`/`name`/descriptor correctness (each getter `length:0`, accessor non-enumerable configurable).
- `Symbol.species` getter on the `RegExp` constructor (§22.2.5.2).

Because the String agent already delegates `String.prototype.match/matchAll/replace/replaceAll/search/split`
to `regexp[Symbol.x]` when present, implementing these lights up String regex delegation too.

## Out of scope / DEFER
- `\p{…}` Unicode property escapes (`property-escapes`, ~900 fails) — needs large Unicode tables.
- `v`-flag `unicodeSets` set operations / string literals (~180) — separate engine.
- inline `(?flags:…)` / `(?flags-flags:…)` regexp-modifiers (~140) — newer grammar.

## Success criteria
- `built-ins/RegExp` passed rises substantially; full sweep 0 panics.
- `language/` no regression (EXIT 0 vs baseline). bench `perf: ok`.
