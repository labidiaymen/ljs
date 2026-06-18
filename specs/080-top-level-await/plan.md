# Plan 080 — Top-Level Await

## Approach
Top-level await reuses the existing §27.7 async-function substrate (a `Generator` with
`is_async = true` running the body on a thread, suspending at each `await`, resumed by Job-queue
reactions). The new work is letting that substrate run a MODULE STATEMENT LIST in a module
environment instead of a function body.

## Files / functions touched
- `src/parser.zig` — `parseModule`: parse the module Program goal with `in_async = true` (module
  top-level is `[+Await]`). No other change: the existing `in_async` guards already (a) make
  `await` the AwaitExpression operator in `parseUnary`, (b) reject `await` as a BindingIdentifier,
  (c) reset `in_async = false` across a nested non-async function so `await` reverts to an
  identifier there. The escaped-`await` keyword check is via the existing reserved-word/escape
  handling. (Module-region only.)
- `src/runtime_types.zig` — add an optional `module_run: ?ModuleRun` slot to `Generator` carrying
  the module record + env so the async-body thread can run module statements (no function object).
- `src/interpreter.zig` (MODULE region only, lines ~223–417 + a new async-module helper):
  - `programHasTLA(program)` — does a module body contain a top-level AwaitExpression (a shallow
    scan that does NOT descend into nested functions)?
  - `runModule` — if the root has top-level await, route to `runModuleAsync` (spawn the async-body
    thread that runs the module statements); else keep the synchronous statement loop unchanged.
  - `runModuleAsync` / a `moduleBodyThread` mirroring `asyncBodyThread` but running
    `m.program.statements` in `m.env`. Terminal completion settles a module promise; the caller
    (`evaluateModule`) reads it after the Job drain.
  - Touch points in shared interpreter.zig: only the module functions + the `Generator` body
    dispatch in `runGeneratorBody`/`asyncBodyThread` need a `module_run` branch. Keep the function
    branch untouched.
- `src/engine.zig` — `evaluateModule`: after `runModule` returns the (possibly pending) module
  completion, run `drainJobs` (already present), then read the module's FINAL settled completion
  for the EvaluationResult.

## Design calls
- **Single awaiting root only.** The corpus's positive `syntax/` + most TLA tests are a single
  module awaiting resolved values; the full multi-module [[PendingAsyncDependencies]] DFS is out of
  scope (documented). If a dependency has TLA we still evaluate it synchronously where possible and
  only the root drives the async block — this covers the dominant corpus shape without the full
  graph-ordering machinery.
- **No perf risk.** The async path is taken ONLY when `programHasTLA` is true. Every non-await
  module (and every script) keeps the exact existing synchronous path — `programHasTLA` is one
  shallow O(statements) scan done once at evaluation, negligible and off the script hot path.

## Constitution Check
- Correctness-leads: implements §16.2.1.6 async module evaluation + §16.2.1.5 `[+Await]` grammar,
  measured by the Test262 `top-level-await` cluster.
- Perf no-regression: async path gated behind `programHasTLA`; scripts and non-await modules
  unchanged. `zig build bench` must stay "perf: ok".
- 0 regressions on `baseline/language.json`.
