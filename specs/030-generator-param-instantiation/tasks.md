# 030 — Tasks

- [x] T1 Diagnose: top `unexpected_error` buckets (`statements/class/dstr` 260 uniq, dominated by
  `gen-meth`/`async-gen-meth` 56 each; mirrored in `expressions/class/dstr` and the
  `generators`/`async-generator` buckets). Root cause = generator params bound lazily at `.next()`
  instead of eagerly at the call site.
- [x] T2 `src/object.zig`: add `Generator.call_env: ?*Environment`.
- [x] T3 `src/interpreter.zig`: extract `instantiateGeneratorParams` (FunctionDeclarationInstantiation)
  from `runGeneratorBody`, returning the bound env + an abrupt completion out-param.
- [x] T4 `createGenerator` / `createAsyncGenerator`: bind eagerly on the caller thread, store
  `gen.call_env`, propagate the abrupt completion (call-site throw) before creating the gen object.
- [x] T5 `runGeneratorBody`: reuse `gen.call_env` when set; async functions still bind on the body
  thread (promise-rejection semantics unchanged).
- [x] T6 `src/engine.zig`: M30 tests (sync-gen + async-gen call-site throw, eager side effect before
  `.next`, non-iterable param TypeError, correct bound values, ordinary-fn parity).
- [x] T7 Gates: `zig build`, `zig build test` (0), `zig build lint` (0/0), full `language/`
  (passed 36455 / 83.5%, no regression vs baseline), `zig build bench` (perf: ok, ljs ≤ Node).
- [x] T8 Update `baseline/language.json`; commit.

## Delta
- `language/` passed 34895 (79.9%) → 36455 (83.5%), **+1560**, 0 regressions.
- `statements/class` 7807→ (was failing 1265 → 849), `expressions/class` 7450 (570 fail).
- `expressions/async-generator` ~284 fail → 76; `statements/generators` 150→46; etc.

## Cause
Generator / async-generator parameter binding (destructuring patterns, default-value expressions,
`arguments`) ran lazily on the body thread at first `.next()` instead of eagerly at the call site
(§15.5.2 / §15.6.2 step 1). Param errors now throw synchronously at the call, as in V8.
