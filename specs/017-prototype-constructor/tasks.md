# M16 tasks — `prototype.constructor`

- [x] T1 `src/builtins.zig`: add `defineConstructorBackref(ctor)` helper
      (`proto.defineData("constructor", {.object=ctor}, true, false, true)`); call it for every
      constructor: Function, Object, the Error family, AggregateError, String, Array, Symbol,
      Promise. Covers `Object.prototype.constructor === Object` and
      `%Function.prototype%.constructor === Function`.
- [x] T2 `src/interpreter.zig`: when an ordinary (non-arrow, non-generator, non-async) function's
      `.prototype` is created, set `prototype.constructor = theFunction` (writable, non-enumerable,
      configurable) via `setConstructorBackref`. Applied at `func_decl` and `evalFunctionExpr`.
- [x] T3 `evalClass`: existing `proto.constructor = ctor` confirmed correct (no change); regression
      tests added.
- [x] T4 `src/engine.zig` tests: built-in/user/class back-references, thrown-error `.constructor`,
      non-enumerable descriptor, and a mini `assert.throws` harness check.
- [x] T5 Gates: build/test/lint green; full `language/` 21378 → 26622 (49.0% → 61.0%), 0 regressions,
      +5244 recoveries; `language/expressions` 10327 → 12718; bench ok (no ljs-vs-self regression).
- [x] T6 Commit + push.

## Cycle delta
- Full `language/` (harness, strict+sloppy): **21378 → 26622** (49.0% → **61.0%**), **+5244**,
  **0 true regressions**.
- `language/expressions`: **10327 → 12718** (48.7% → 59.9%).
- Recoveries by area: statements 2732, expressions 2391, eval-code 59, literals 20, others ~60.
- Bench: perf ok, ljs ≤ Node (0.2x–0.6x), no ljs-vs-self regression.
