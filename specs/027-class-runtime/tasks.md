# M27 — Tasks

- [x] T1 Build ReleaseFast; capture full `language/` baseline (passed=31239, 71.5%).
- [x] T2 Collect + categorize `class/*` `unexpected_error` failures (1558 unique).
      Dominant bucket: `dstr` (984); top sub-cause `*-id-init-fn-name-*` (~288).
- [x] T3 Reproduce minimally: destructuring/param default with anonymous function
      initializer does not get the binding-identifier `name` (broken in all contexts).
- [x] T4 Fix: perform §8.4 NamedEvaluation when a default initializer is applied to a
      single-identifier binding/assignment target.
      - [x] array binding-pattern element defaults (`bindPattern` `.array`)
      - [x] object binding-pattern property defaults (`bindPattern` `.object`)
      - [x] ordinary call param defaults (`callFunction`)
      - [x] generator-body param defaults (`runGeneratorBody`)
      - [x] assignment-pattern identifier default (`assignElement` `.assign`)
- [x] T5 Add `src/engine.zig` regression tests for each context.
- [x] T6 Gates: build / test / lint(0,0) / conformance (≥31239, no regression) / bench.
- [x] T7 Update baseline; commit if all green.
