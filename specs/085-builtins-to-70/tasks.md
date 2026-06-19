# Tasks 085 — Built-ins to 70%

## Wave 1 (parallel: distinct files)
- [x] W1-Date `Date` (§21.4) — new `src/builtin_date.zig`: constructor (all overloads), now(), parse,
  UTC, the get/set/toXxx prototype methods, toISOString/toJSON, Symbol.toPrimitive. (~1,188 fails)
  → DONE: built-ins/Date 0→1156/1188 (97.3%), 0 panics. UTC==local; getTimezoneOffset 0. Deferred:
  toTemporalInstant (Temporal, out of scope), proto-from-ctor-realm / subclassing / is-a-constructor
  (shared cross-realm NewTarget limitation), toJSON.call(primitive) (shared boxing-vs-live-prototype gap).
- [ ] W1-Object `Object` (§20.1) — fill the prototype/static method gaps in `src/builtin_object.zig`
  (getOwnPropertyDescriptors, fromEntries, hasOwn, groupBy, accessor-defaults, etc.). (~1,173)
- [ ] W1-Array `Array` (§23.1) — method-family gaps in `src/builtin_array.zig` (flat/flatMap, at,
  group, copyWithin, toSorted/toReversed/toSpliced/with, Array.from edge cases). (~1,300)
- [x] W1-String `String` (§22.1) — gaps in `src/builtin_string.zig` (normalize, well-formed,
  matchAll, replaceAll, localeCompare, padStart/End edge cases, Symbol methods). (~686)
  DONE: registered match/matchAll/search/isWellFormed/toWellFormed/normalize; @@match/@@matchAll/
  @@search/@@replace/@@split delegation (IsObject-gated); IsRegExp guards on includes/startsWith/
  endsWith; Unicode-whitespace trim; code-unit padStart/padEnd; repeat(undefined)→""; isWellFormed/
  toWellFormed surrogate-pair logic (string_utf16.zig); String() ctor → "" (interp_native.zig).
  built-ins/String 1757→1967 / 2443 (71.9%→80.5%), 0 panics, 0 regressions. Deferred: full Unicode
  normalize (NFC/NFD/NFKC/NFKD tables), the implicit-RegExp fallback for match/search/split (needs
  the RegExp engine, Wave 2), tagged-template String.raw (parser), and Object(primitive) boxing +
  native-method `.prototype===undefined` (shared infra / Object agent).
- [ ] W1-GATE integrate sequentially; full built-ins sweep 0 panics + language 0-reg + bench; push; measure.

## Wave 2 (parallel)
- [ ] W2-RegExp · W2-Promise · W2-Function · W2-Iterator — see spec. GATE + push + measure.

## Wave 3 (mop-up, parallel small pools)
- [ ] W3 Error/JSON/Proxy/Symbol/Map-Set/Math/WeakRef/FinalizationRegistry/DisposableStack + TA edges.

## Close
- [ ] Built-ins ≥ 70%; update baseline; set spec Status Done with the delta.
