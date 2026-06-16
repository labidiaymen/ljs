# M15 — `eval` tasks

- [x] T1: Add `NativeId.eval_fn` to `src/object.zig`.
- [x] T2: Install `eval` global (+ mirrored on globalThis via the existing setup loop)
      in `src/builtins.zig`.
- [x] T3: Factor `performEval(source, target_env)` in `src/interpreter.zig`: parse
      (SyntaxError on failure) + run on the same interpreter (counters preserved).
- [x] T4: Indirect path: `callNative(.eval_fn, ...)` → performEval in the GLOBAL env.
- [x] T5: Direct path: in `evalCall`, detect callee == identifier "eval" resolving to
      the %eval% intrinsic → performEval in a fresh CHILD of the caller's env.
- [x] T6: Tests in `src/engine.zig` (the eight acceptance cases).
- [x] T7: Gates — `zig build`, `zig build test`, `zig build lint`, conformance diff,
      bench. Commit only if all green.
