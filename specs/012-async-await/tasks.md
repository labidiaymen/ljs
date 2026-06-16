---
description: "Task list for M11 — async/await (§15.8 / §15.6 / §15.9, contextual `async`/`await`, parsing + early errors; runtime deferred to Cycle 2)"
---

# Tasks: M11 — Async / Await

**Metric:** conformance reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`), same as M4–M10. The PRIMARY gate is the FULL `language/` tree
(`baseline/language-expressions.json` remains the `language/expressions` continuity floor). M11 Cycle 1
recovers the async SYNTAX + §15.8 early-error tests (NOT `[async]`-flagged, so the runner already
executes them); the `[async]`-flagged executable tests need the event loop and stay skipped (Cycle 2).

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + **bench (ljs ≤ Node)**
green). Re-measure the FULL `language/` tree each cycle (primary) + the `language/expressions` continuity.

**Mandatory regression hunt (every cycle):** un-rejecting async syntax converts parse-negatives into
reachable runtime — but the §15.8.1 early errors must keep the genuine negatives red, and `[async]`
executables are skipped. `git stash` (or `--update-baseline` BEFORE) + rebuild ReleaseFast + measure
BEFORE vs AFTER on the FULL `language/` tree, sort + `comm`; true regressions 0 or far outweighed by
recoveries. Watch: un-rejecting `async function` un-masks finer-grained early errors (await-as-label,
formals/body duplicate, async-fn-as-substatement, ContainsAwait in a static block) — add each precise
early error so the net is non-negative.

## Cycle 1 — `async`/`await` PARSING + §15.8 early errors (runtime deferred) 🎯 (DONE)

**Result (full `language/` tree, harness): passed 16,007 → 16,117 (+110), 46.6% → 47.0%. Regression
hunt by `mode+path`: 111 recoveries / 1 regression (111:1). The single regression —
`statements/await-using/redeclaration-error-from-within-strict-mode-function-await-using.js#sloppy` — is
a pre-existing CUT my async parsing merely un-masked: it asserts a §14.3.1 redeclaration SyntaxError for
the `await using` declaration (the `explicit-resource-management` PROPOSAL, not implemented in ljs);
previously `await using f` parse-failed for the wrong reason (giving the right outcome by accident), now
`await using` parses as the await operator applied to `using`. Not a real breakage; offset by 2
`await-using/syntax` recoveries. The 111 recoveries are entirely async syntax: async function decl/expr,
async generators, async arrows, async methods (class + object, static/computed), `await` expressions, and
async-function declarations in if/for/while/labeled positions. Continuity `language/expressions`: 8,024 →
8,066 (+42), 47.3% → 47.5% (gained — async syntax lives heavily there). Bench: `perf: ok (no ljs-vs-self
regression)`, ljs 0.2–0.5× Node — parse-only changes, no hot-path impact (the async-call dispatch is a
single optional-field test before the existing generator check). No hangs. Runtime (Promise +
microtask/Job queue + the await suspension) DEFERRED to Cycle 2.**

- [x] M11-T010 **AST — `is_async` flag + `await_expr` node (`src/ast.zig`)** — `Function.is_async: bool`
  (alongside `is_generator`); an `await_expr: *const Node` node (§15.8 AwaitExpression operand).
- [x] M11-T020 **Parser — `in_async` context + async function/arrow/method parsing + `await` operator
  (`src/parser.zig`)** — `in_async` flag (saved/restored around every function body; set for async
  fns/arrows/methods; false for ordinary; an async generator sets BOTH `in_async`+`in_generator`).
  `async` is a contextual modifier only when followed (no LineTerminator) by `function` / an arrow head.
  Parse: `async function f(){}` decl + expr, `async function* g(){}`; async arrows (`async x =>`,
  `async (…) =>`, `async () =>`) via the arrow cover-grammar; async methods in class/object bodies
  (`async m(){}`, `async *m(){}`, `static async`, computed); the `await UnaryExpression` operator at the
  UnaryExpression precedence inside an async body (an ordinary identifier outside async).
- [x] M11-T030 **Parser — §15.8.1 / §15.6.1 early errors (`src/parser.zig`)** — `await` as a
  BindingIdentifier in an async context (function name / param / body `var`/`let`/`const`, async-arrow
  param); `await` reaching IdentifierReference position inside async; `await` as a LabelIdentifier in
  async; async/async-generator UniqueFormalParameters; FormalParameters BoundNames ∩
  body LexicallyDeclaredNames; `(await x)++` / `++(await x)`; `async function` declaration in
  substatement position; async-arrow params parse `[+Await]` (await reserved through nested arrows);
  a ClassStaticBlock resets `in_async`/`in_generator` (ContainsAwait stays a Syntax Error there).
- [x] M11-T040 **Object/Interpreter — `is_async` + runtime stub (`src/object.zig`,
  `src/interpreter.zig`)** — `FunctionData.is_async`; `evalFunctionExpr` / func-decl creation carry it;
  calling an async function and evaluating an `await_expr` raise a deferred-runtime error (parse/early-
  error tests never reach runtime; executable async tests are `[async]`-skipped). Ordinary call path
  untouched (bench-neutral).
- [x] M11-T050 **Tests (`src/engine.zig`, all green)** — `typeof (async function(){})` → "function";
  `async function f(){}` parses; `async () => 1` parses; `{ async m(){} }` / `class C{ async m(){} }`
  parse; `await` as identifier in a non-async function works (→ 1); `await` as a BindingIdentifier inside
  an async function → SyntaxError. Updated the two obsolete M4 tests that asserted async methods
  parse-reject.
- [x] **Conformance + regression hunt (harness, ReleaseFast, BEFORE vs AFTER `comm`):** full `language/`
  `passed ≥ 16,007`; 0 true regressions or far outweighed by recoveries; `language/expressions ≥ 8,024`.
  Bench green.
- [x] **Landed:** async function decl/expr, async generators, async arrows, async methods (class +
  object, static/computed), the `await` operator + the §15.8.1 early errors. **Deferred to Cycle 2:**
  the async RUNTIME — Promise, the microtask/Job queue, async-fn [[Call]] returning a Promise, the
  `await` suspension/resume, and the Test262 runner's `[async]` / `$DONE` support.

## Cycle 2 — async RUNTIME 🎯 (DONE)

**Result (full `language/` tree, harness): passed 16,117 → 16,326 (+209), 47.0% → 37.4%. The `%`
DROPPED only because un-skipping `[async]` tests changed the denominator — `skipped` fell 5,594 → 809
(~4,785 previously-skipped async executables now RUN; many of the deferred ones — async generators,
`for await` — fail), and `%` = passed/(passed+failed) so the added failures dilute it. The gate metric is
`passed` (≥ 16,117) and the per-test regression diff, not the ratio. Regression hunt by `mode+path`
(`--update-baseline` BEFORE vs AFTER + `comm`): 209 recoveries / 0 TRUE regressions. All 209 recoveries
are async runtime: `statements/async-function` (44), `expressions/async-function` (30),
`expressions/async-arrow-function` (26), `expressions/await` (10), async object/class methods (~50),
forbidden-ext annex-B async (~25). Continuity `language/expressions`: 8,066 → 8,192 (+126). Bench:
`perf: ok (no ljs-vs-self regression)`, ljs 0.2–0.6× Node — ordinary calls pay only one extra optional-
field branch (the `is_async` test after the existing `is_generator` check); the Job drain on a
promise-free script is a no-op (empty queue). NO HANGS: a never-settling `await` is reaped at realm
teardown (reuses `cleanupGenerators`); a runaway microtask loop is bounded by the step watchdog
(`drainJobs` ticks per job → `step_limit`, not a hang) — both verified.**

- [x] **Promise core (§27.2)** — a Promise object (`Object.promise: ?*PromiseData` — state / result /
  fulfill+reject reaction lists). `new Promise(executor)` (§27.2.3.1, executor `(resolve, reject)`,
  executor-throw rejects); `Promise.prototype.then(onF, onR)` (§27.2.5.4, returns a derived promise,
  schedules reactions as JOBS); `catch` (§27.2.5.1), `finally` (§27.2.5.3, value/thrower thunks);
  `Promise.resolve(x)` (§27.2.4.5 — already-a-promise passthrough, thenable adoption) / `Promise.reject`
  (§27.2.4.4). Resolving with a thenable schedules a PromiseResolveThenableJob (§27.2.1.3.2). Single
  settlement via `[[AlreadyResolved]]`.
- [x] **Microtask / Job queue (§9.5)** — a FIFO (`Interpreter.job_queue`, shared across the main +
  async-body interpreters). `enqueueJob` (HostEnqueuePromiseJob); `drainJobs` runs the queue to empty
  after the script returns (engine), step-bounded (no hangs), compacting the consumed prefix. Reaction
  jobs (§27.2.2.1) + thenable jobs (§27.2.2.2).
- [x] **Async function runtime (§27.7)** — calling an `is_async` function returns a Promise immediately
  and runs the body on the GENERATOR thread substrate (`Generator.is_async = true`, reusing the
  ping-pong handoff + teardown). `await x`: PromiseResolve(x), suspend the body (carry the value out),
  register internal fulfill/reject reactions that RESUME the body thread (fulfill → await value; reject
  → throw at the await). Normal return resolves / uncaught throw rejects the function's promise. Async
  arrows + async methods (object/class, static/computed) reuse the same path.
- [x] **Runner `[async]` support** — the runner no longer SKIPS `meta.flags.is_async`; `evaluateAsyncTest`
  injects a native `$DONE(err)` global, runs, DRAINS the Job queue, and classifies: PASS iff `$DONE`
  called with no/falsy arg; FAIL on a truthy arg, never-called, sync throw, parse error, or step-limit.
  Non-async tests are unchanged (they drain a now-usually-empty queue — a no-op).
- [x] **Tests (`src/engine.zig`, all green)** — async fn fulfills with the return value (42); `await`
  of `Promise.resolve(3)` continues (→ 4); `await` of a rejected promise is `try/catch`-catchable;
  uncaught async throw rejects (observed via `.then` onRejected); `then` chaining, thenable adoption,
  microtask-after-sync ordering, `catch`/`finally`; `new Promise` resolve/reject + executor-throw +
  non-callable-executor TypeError. A post-drain global-read test helper (`evalGlobalAfterDrain`) gives
  deterministic assertions (no real timers).

**Deferred (note, not attempted this cycle):** `Promise.all`/`race`/`allSettled`/`any`; async
generators (`async function*` — currently routed through the plain-async path: the body runs but `yield`
has no async-generator surface) + `for await`; AsyncFromSyncIterator; Promise subclassing / `@@species`;
`globalThis` (so `asyncHelpers.js`'s `asyncTest` — which checks `globalThis.$DONE` ownership — works;
those ~127 tests fail rather than pass, but were skipped before so it's not a regression). The
`finally` onFinally is called synchronously (its returned promise is not awaited) — a minor §27.2.5.3.1
simplification.
