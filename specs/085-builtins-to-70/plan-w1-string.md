# Plan 085 W1 — String (§22.1) method gaps

## Approach
MEASURE-then-fill over `built-ins/String` (2,443 tests, 686 failing at start). Extend the existing
`src/builtin_string.zig` (already UTF-16 code-unit-aware via `src/string_utf16.zig`). Keep shared-file
edits localized to String's native ids so sibling Date/Object/Array agents don't conflict.

## Files / functions touched
- `src/builtin_string.zig`
  - Register-dispatch new methods: `match`, `matchAll`, `search`, `isWellFormed`, `toWellFormed`,
    `normalize`.
  - `isRegExp(it, v)` — §22.2.7.2 IsRegExp (reads `v[@@match]`, may throw; falls back to the internal
    `.regexp` slot). Guards `includes`/`startsWith`/`endsWith` (§22.1.3.8/.23/.7 reject a RegExp arg).
  - `matchLike` (match/search) + `matchAll` — IsObject-gated GetMethod(arg, @@x) delegation; without a
    RegExp engine wired to the Symbol methods the implicit-RegExp fallback returns null/-1 (best effort).
  - `replace`/`replaceAll` — @@replace delegation (IsObject-gated) + replaceAll non-global-RegExp
    TypeError; `split` — @@split delegation (limit passed uncoerced).
  - `trim`/`trimStart`/`trimEnd` — Unicode WhiteSpace/LineTerminator over code points (`isWsCp`,
    `cpStart`), replacing the byte-level ASCII-only `isStrWs`.
  - `pad` (padStart/padEnd) — rewritten to code-unit lengths (filler truncated at a code-unit boundary).
  - `repeat` — undefined arg → 0 (was +Inf → spurious RangeError).
  - `normalize` — form validation (NFC/NFD/NFKC/NFKD else RangeError) + identity for already-normalized
    input. Full Unicode tables deferred.
- `src/string_utf16.zig` — `isWellFormed` / `toWellFormed` (unpaired-surrogate detection / U+FFFD
  replacement, with adjacent-surrogate-pair recognition).
- `src/interp_native.zig` (`.string_ctor`) — §22.1.1.1 step 1: `String()` with no arg → `""` (was
  `"undefined"`), fixing `new String()` wrapper receivers.
- `src/builtins.zig` — register the six new String methods (lengths already in `nativeLength`).

## Constitution check
Correctness-first; no perf hot path touched (string built-ins are not the bench loops). Bench gate:
no ljs-vs-self regression. Language: 0-regression vs `baseline/language.json`.

## Out of scope / deferred
Full Unicode `normalize` (decomposition/composition tables), the implicit-`new RegExp` fallback for
match/search/split/matchAll (needs the Wave-2 RegExp engine), tagged-template `String.raw` syntax
(parser), and the cross-cutting `Object(primitive)` boxing + native-method `.prototype===undefined`
infra (Object agent / a shared cycle).

## Result
built-ins/String 1,757 → 1,967 / 2,443 (71.9% → 80.5%), 0 panics, 0 regressions.
