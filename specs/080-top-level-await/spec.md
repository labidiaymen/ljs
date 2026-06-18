# Spec 080 — Top-Level Await for ES Modules (ECMA-262 §16.2.1.6, §27.7)

Status: Done — module-code passed 268→488 (+220); top-level-await 5→232/253; language
passed 39751→39984 (+233), 0 regressions vs baseline/language.json. zig build/test/lint/bench green.

## Summary
Finish the highest-leverage deferred module item from spec 070: **top-level await** (`[async]` /
top-level-await module evaluation). At module top level the AwaitExpression is grammatically
permitted (`ModuleItem` is parsed with `[+Await]`), and an awaiting module evaluates as an async
graph: its body suspends at each `await`, the awaited promise's settlement resumes it via the
realm Job queue, and the module's evaluation Completion is the body's final completion.

`vendor/test262/test/language/module-code/top-level-await/` has 287 tests, of which 238 fail at
baseline — by far the largest module-code failure cluster (the next, `namespace`, is 24). 211 of
those are `syntax/` tests: 206 POSITIVE (`await <expr>;` at top level, run to normal completion)
plus 5 NEGATIVE parse tests (`await 0;`, `await` doesn't propagate into a nested non-async
function body).

## Governing clauses
- §16.2.1.6 Cyclic Module Records — `Evaluate`, `InnerModuleEvaluation`, `ExecuteAsyncModule`,
  `AsyncModuleExecutionFulfilled` / `…Rejected`. A module with `[[HasTLA]]` true evaluates
  asynchronously: ExecuteAsyncModule wraps the body in a capability-driven async block.
- §16.2.1.5 ModuleItem grammar — `StatementListItem[~Yield, +Await, ~Return]`: at module top level
  `await` is the AwaitExpression operator, NOT an IdentifierReference. `await` may not be a
  BindingIdentifier. The `await` keyword may not be escaped (`await`).
- §27.7.5.3 Await(value) — the async-body suspension/resume machinery (already implemented for
  async functions; reused here).

## In scope
- Parser: module top-level code parses with `[+Await]` (set `in_async = true` for the module
  Program goal). `await` operator at top level + inside top-level blocks; `await` as a
  BindingIdentifier and an escaped `await` keyword are SyntaxErrors; `await` reverts to an
  IdentifierReference inside a nested NON-async function (await does not propagate).
- Interpreter: an async module-evaluation path. When the module graph contains a top-level
  `await`, run the root body on an async-body thread (reusing the §27.7 Generator substrate), so
  `await` suspends and the realm Job-queue drain resumes it. The module's final completion is the
  body's terminal completion (normal → module fulfilled; throw → module rejected). Modules with NO
  top-level await keep the existing synchronous evaluation path unchanged.
- Engine `evaluateModule`: after `runModule` + `drainJobs`, surface the awaiting module's FINAL
  settled completion (not the intermediate pending state) as the EvaluationResult.

## Out of scope
- Multi-module async ordering subtleties beyond what the corpus's positive tests exercise (the
  full §16.2.1.6 [[AsyncEvaluation]] / [[PendingAsyncDependencies]] DFS ordering across a graph of
  several awaiting modules). A single awaiting root (the common corpus shape) is handled.
- `import.meta` runtime object, `export *` enumeration/ambiguity (separate deferred items).

## User scenarios (Given / When / Then)
1. Given `var foo = 1; { … { await foo; } … }` at module top level (a positive `syntax/` test),
   When evaluated as a module, Then `await` parses + runs and the module completes normally → PASS.
2. Given `await 0;` at module top level, When parsed, Then a SyntaxError (escaped `await`
   keyword) → PASS (was a parse failure / wrong outcome).
3. Given `function fn() { await 0; }` at module top level, When parsed, Then a SyntaxError
   (`await` is an IdentifierReference inside the non-async fn body, so `await 0` is ungrammatical)
   → PASS.
4. Given a module that `await`s a rejected promise at top level, When evaluated, Then the module
   evaluation rejects with that reason (a runtime-negative module classifies on the error name).
5. Given a non-await module / any existing baseline test, When run, Then it still passes (0
   regressions) — the synchronous evaluation path is unchanged when there is no top-level await.

## Success criteria
- `top-level-await/syntax` positive + negative tests pass; the broader `top-level-await` cluster
  rises substantially. module-code passed > 268 baseline.
- 0 regressions on `language` vs `baseline/language.json`.
- `zig build`, `zig build test`, `zig build lint` green; `zig build bench` no regression.
