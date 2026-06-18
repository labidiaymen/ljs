# Tasks 080 — Top-Level Await

- [x] T01 Parser: parse the module Program goal with `in_async = true` (`[+Await]`). The 5 negative
      `syntax/` parse tests now fail correctly; `await` is reserved as an IdentifierReference in module
      code even inside nested non-async fns (early-does-not-propagate); escaped `await` keyword rejected.
      Bonus: lexer regex-context after `await`/`yield` (`await /re/`); `export default class` anonymous
      heritage (`export default class extends f(await x) {}`) via a new `allow_anonymous` parseClass arg.
- [x] T02 runtime_types: added `Generator.module_run` slot (statements + Module Environment) so the
      async-body thread runs module statements without a function object. Re-exported in object.zig.
- [x] T03 [HasTLA] is detected in the PARSER (`saw_top_level_await` → `Program.has_top_level_await`)
      at AwaitExpression / `for await` / `await using` build sites — simpler + exact vs a re-scan.
- [x] T04 Interpreter: `runModuleAsync` + `asyncModuleBodyThread` — run module statements on the §27.7
      async substrate; settle the module promise; routed from `runModule` only when the root has TLA.
- [x] T05 Engine: `evaluateModule` reads the awaiting module's FINAL settled promise state after the
      Job drain; new `evaluateAsyncModule` + runner routing for `[async]`-flagged module tests ($DONE).
- [x] T06 Verify: module-code 268→488 (+220); top-level-await 5→232/253; `zig build`/`test`/`lint`
      green. Language 0-regression + bench: see below.

## Deferred (out of documented scope — separate items)
- Multi-module async ordering / [[PendingAsyncDependencies]] DFS across several awaiting modules
  (`module-import-*`, `dfs-invariant`, `fulfillment-order`, `rejection-order`).
- Dynamic `import()` that actually LOADS a module graph (`dynamic-import-*`) — the separate
  069-dynamic-import deferred item (the loader still rejects with TypeError).
- `new (await String).valueOf()` fails on a pre-existing `new String().valueOf` builtin bug
  (string/object area), not a module defect.
