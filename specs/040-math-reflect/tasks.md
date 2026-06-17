# 040 — Tasks

## Part A — Math
- [ ] T1  `object.zig`: add `reflect_method` NativeId.
- [ ] T2  `interpreter.zig` `mathMethod`: add the missing §21.3.2 methods
        (`sin cos tan asin acos atan atan2 sinh cosh tanh asinh acosh atanh exp expm1
        log log2 log10 log1p cbrt hypot fround clz32 imul random`); fix `round`
        edge cases (-0 / large ints) and keep `sign`/`max`/`min` correct.
- [ ] T3  add a fixed-seed xorshift64* RNG state to the interpreter for `Math.random`.
- [ ] T4  `builtins.zig`: register the new method names on the Math object; install the
        §21.3.1 value properties (`E LN10 LN2 LOG10E LOG2E PI SQRT1_2 SQRT2`) +
        `Symbol.toStringTag = "Math"`.

## Part B — Reflect
- [ ] T5  `interpreter.zig`: add `reflectMethod(name, args)` dispatch; wire
        `.reflect_method` into `callNative`.
- [ ] T6  implement each Reflect method via existing internals; extend `construct` to
        accept an explicit newTarget (instance proto from newTarget.prototype).
- [ ] T7  `builtins.zig`: install the `Reflect` namespace object + its methods +
        `Symbol.toStringTag = "Reflect"`.

## Tests + gates
- [ ] T8  `engine.zig`: M40 unit tests (Math sign/trunc/hypot/log2/clz32/max-NaN;
        Reflect has/get/ownKeys/apply/construct/defineProperty/get-on-primitive-throws).
- [ ] T9  `zig build` / `zig build test` / `zig build lint`.
- [ ] T10 conformance: Math + Reflect passed ↑, 0 within-target regressions;
        `language/` no regression.
- [ ] T11 `zig build bench` perf ok, ljs ≤ Node.
- [ ] T12 fill the before→after deltas below; commit if all green.

## Deltas (filled at completion)
- Math:    181/654 (27.7%) -> 529/654 (80.9%)  [+348, 0 regressions]
- Reflect: 0/306 (0%)       -> 210/306 (68.6%)  [+210, 0 regressions]
- language: no regression (Y) — "ok (no regression vs baseline)"
- bench: perf ok (no ljs-vs-self regression); ljs 0.2–0.4x of Node.

All tasks T1–T12 complete.
