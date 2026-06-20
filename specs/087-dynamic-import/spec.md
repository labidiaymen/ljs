# Spec 087 — Dynamic `import()` in script / async-test context (§13.3.10 ImportCall)

Status: Done — `dynamic-import` 1083→1360 passing (+277); language tree 40,733 → 41,048 (+315),
91.6% → 92.3%, 0 regressions vs baseline, 0 panics, bench ok. Remaining bucket fails are live-binding
namespace updates (`usage`/`namespace`), ambiguous/circular import detection (`catch/instn-iee-*`),
and out-of-scope proposals (import.defer / import.source / import-attributes) — next cycles.
Owner: Aymen
Conformance target: `language/expressions/dynamic-import` — currently 0 passing of ~815;
target the ~293 *standard* `unexpected_error` files (≈+450–550 test-instances over strict+sloppy).

## Problem

`import(specifier)` parses (AST `import_call`, §13.3.10) but the runtime `evalImportCall`
unconditionally rejects the returned promise with a `TypeError("module loading is not supported")`
because no module loader is in scope for *script* evaluation. The module-loading machinery
(`loadGraph`, `linkModule`, `instantiateModule`, `evaluateModule`, `moduleNamespace`) already exists
and is wired into `[module]` tests via `evaluateModule`/`evaluateAsyncModule`, but **script-context
dynamic import** — the entire `expressions/dynamic-import` bucket, mostly `flags:[async]` tests that
go through `evaluateAsyncTest` — gets no loader.

The Test262 minimal harness loader (`ModuleLoaderCtx` in `test262/runner.zig`, charter-permitted)
already resolves a relative specifier to a sibling file. It just needs to be threaded into the
interpreter for script and async-test evaluation.

## Scope

In scope (ECMA-262 §13.3.10 ImportCall + §16.2.1.6 HostLoadImportedModule, minimal-loader form):
- Thread the existing `ModuleLoader` + a per-test module cache + the referrer key onto the
  `Interpreter`, set by loader-aware engine entry points.
- `evalImportCall` resolves the specifier relative to the referrer, loads+links+evaluates the target
  module graph (cached by key — a re-import returns the same namespace, no re-evaluation), and
  **fulfills** the import() promise with the module namespace object, or **rejects** with the module's
  thrown error / a SyntaxError (parse/resolve failure) / a TypeError (unresolvable specifier).
- Dynamic `import()` *inside* a module resolves relative to that module's key (referrer tracked
  during module-body evaluation).

Out of scope (proposals, not ECMA-262 — these stay failing/parse-error):
- `import.defer(...)` (import-defer), `import.source(...)` (source-phase imports).
- Import attributes / `import(x, { with: … })`.
- Top-level-await *inside a dynamically-imported* module (rare in this corpus; fixtures are simple
  `export` modules). A TLA fixture evaluates synchronously and may not fully settle — acceptable miss.

## Acceptance (Given/When/Then)

- **Given** a script `await import('./module-code_FIXTURE.js')`, **When** evaluated under the harness
  loader, **Then** the promise fulfills with a namespace whose exports (`local1`, `default`, …) read
  the fixture's evaluated bindings.
- **Given** `import('./does-not-exist.js')`, **Then** the promise rejects (TypeError) and a
  `.catch` handler observes it.
- **Given** a fixture module that throws at evaluation, **Then** `import(...)` rejects with that error.
- **Given** two `import()` calls for the same specifier, **Then** both fulfill with the *same*
  namespace object and the module body evaluates once.
- **Regression:** language tree shows **0 regressions** vs `baseline/language.json`; bench unchanged.

## Success criteria

- `expressions/dynamic-import` standard `usage` / `namespace` / `catch` / `assignment-expression`
  tests pass; language conformance rises by the bucket delta (measured at gate).
- `zig build` + `zig build test` + `zig build lint` + `zig build bench` green; 0 panics on the
  full `language/` sweep.
