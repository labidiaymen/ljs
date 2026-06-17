# M38 Tasks

## Part A — sparse/lazy array length
- [x] T1 Add `array_length: usize` + `sparse: ?*AutoHashMapUnmanaged(usize, Value)` to `Object`.
- [x] T2 Object helpers: `arrayLen`, `arrayGet(i)`, `arraySet(i, v)`, `arraySetLen(n)` with the
      dense/sparse policy (GAP_CAP grow, else sparse).
- [x] T3 Route interpreter array branches through the helpers: `getProperty`/`setProperty` length+
      index, `in`, `delete`, `getOwnProperty`, `getOwnPropertyNames`, `enumerateKeys`, iterator
      `next`, `hasOwnProperty`. Keep `array_length` in sync wherever `elements` is appended directly
      (literals, push, spread, Array ctor, slice/map outputs, etc.) — add a `pushElement` helper or
      bump `array_length` on append.
- [x] T4 `built-ins/Array` run completes (no OOM); engine test `var a=[];a.length=100;a.length===100`.

## Part B — methods (§23.1.3) — GREEN SLICE landed (0 regressions)
- [x] T5 Iteration/search LANDED: every, some, find, findIndex, findLast, findLastIndex, reduce,
      reduceRight, lastIndexOf, at, map (+ indexOf/includes/slice/join improvements). Holes skipped
      per spec; arg coercion throws on Symbol (ToIntegerOrInfinity); HasProperty walks the proto chain.
- [x] T6 Mutation LANDED (in-place, no result-array creation): reverse, fill, copyWithin, sort.
- [~] DEFERRED to follow-up (would regress Test262 species/non-extensible-target/frozen-length tests
      that pass today via a missing-method throw): concat, splice, filter, flat, flatMap, shift,
      unshift, Array.from, Array.of. These need ArraySpeciesCreate-with-throw + a frozen/non-extensible
      [[Set]]/CreateDataPropertyOrThrow — out of the M-subset. Their implementation is present in
      `builtin_array.zig` but NOT registered, so they are inert until that machinery lands.
- [x] T8 Register the green-slice names on Array.prototype in `builtins.zig`.

## Verify
- [x] T9 engine.zig tests (filter/reduce/find/sort/reverse/flat/from/of/sparse-length/splice/at).
- [x] T10 gates: build, test, lint, conformance (both baselines, no regression; built-ins ≥7744),
      bench (dense path unchanged).
