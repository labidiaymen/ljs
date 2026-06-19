# Plan — 086 RegExp prototype Symbol methods (§22.2)

## Approach
New file `src/builtin_regexp_symbol.zig` holds the five well-known-Symbol prototype methods plus the
§22.2.7 abstract ops (RegExpExec honoring an overridden `exec`, AdvanceStringIndex, GetSubstitution)
and the §22.2.9 %RegExpStringIteratorPrototype%. `src/builtin_regexp.zig` gains `RegExp.escape`
(§22.2.5.2 EncodeForRegExpEscape), the IsRegExp / from-regexp-like constructor branch, a generic
`get flags` (§22.2.6.4), and a `d`-flag `indices` array in builtinExec.

These methods are GENERIC (read `exec`/`flags`/`global`/`unicode`/`lastIndex` as ordinary properties),
so once keyed by the realm's well-known `Symbol.match/replace/…` identities they also drive the String
agent's already-present `String.prototype.{match,replace,split,search,matchAll}` @@-delegation.

## Files / functions touched (RegExp-localized)
- `src/builtin_regexp_symbol.zig` (new) — match/matchAll/replace/search/split + RegExpStringIterator.
- `src/builtin_regexp.zig` — `escape`, `isRegExp`, generic `get flags`, `indices` in builtinExec,
  THROWING Set(lastIndex).
- `src/runtime_types.zig` — native ids `regexp_symbol_method` / `regexp_string_iterator_next` /
  `regexp_static`.
- `src/interp_native.zig` — dispatch for the three new ids (RegExp-localized).
- `src/object.zig` — `nativeLength` entries for the RegExp methods/getters/escape.
- `src/builtins.zig` — register the @@-Symbol methods (keyed by well-known identities), the
  `RegExp[Symbol.species]` getter, and `RegExp.escape`.

## Key design calls
- **Throwing Set(lastIndex):** the spec's RegExp methods use `Set(R,"lastIndex",v,true)` (Throw=true).
  Using the ordinary [[Set]] (Throw=`strict`) lets a non-writable `lastIndex` silently no-op in sloppy
  mode → the global match/replace loop never advances → infinite loop. Fixed via `setKeyThrow`.
- **RegExpStringIterator state** stored as own non-enumerable `##`-prefixed data props on the opaque
  iterator (no new Object slot needed).
- **AdvanceStringIndex** operates in the byte/WTF-8 domain (advance past the whole multi-byte sequence
  when `unicode`), consistent with ljs's pre-UTF-16 string storage.

## Constitution Check
- Correctness-leads: pure ECMAScript §22.2, no host APIs. DEFER `\p{}` / `v`-sets / inline modifiers.
- Perf no-regression: changes are confined to RegExp built-ins, off the interpreter hot path; bench
  `perf: ok`.
