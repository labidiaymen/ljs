---
description: "Task list for M13 — async generators + for-await (§27.6 / §14.7.5 / §27.1.4), reusing the M9 generator thread substrate + M11 Promise/Job runtime"
---

# Tasks: M13 — Async Generators + `for await`

**Metric:** conformance WITH the Test262 harness prelude (`--harness-dir vendor/test262/harness`). The
PRIMARY gate is the FULL `language/` tree. BASELINE: **passed=16,609 / 38.0%**; `language/expressions`
floor **8,320**.

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + bench green; no hangs).

**Mandatory regression hunt:** `--update-baseline` BEFORE + `--baseline` AFTER on the FULL tree; true
regressions 0 or far outweighed by recoveries. Watch for HANGS (a deadlocked request-queue / await
never finishes).

## Cycle 1 — async generators + for-await + AsyncFromSyncIterator + async yield* 🎯

- [x] M13-T010 **AST — `for await` flag (`src/ast.zig`)** — `for_of_stmt.is_await: bool` (§14.7.5.6
  async iteration hint).
- [x] M13-T020 **Parser — `for await` (`src/parser.zig`)** — parse the optional `await` after `for`
  (async-context check: SyntaxError outside `in_async`; `of`-form only — no for-in / C-style); thread
  `is_await` into the for-of node. Async-gen methods already set `is_async`+`is_generator` (M11 C1).
- [x] M13-T030 **Object — AsyncGenerator + AsyncFromSync state (`src/object.zig`)** —
  `Generator.is_async_gen`/`transfer_await`/`async_gen`; `AsyncGeneratorState`, `AsyncGenRequest`,
  `AsyncGenerator` (gen + request queue); `Object.async_generator`/`async_from_sync`; NativeIds
  (`async_generator_method`/`_iterator`, `async_from_sync_method`/`_wrap`); `afs_done` slot.
- [x] M13-T040 **Builtins — prototypes + Symbol.asyncIterator (`src/builtins.zig`)** —
  `%AsyncGeneratorPrototype%` (next/return/throw + `[Symbol.asyncIterator]()`→this);
  `%AsyncFromSyncIteratorPrototype%` (next/return/throw + asyncIterator). `Symbol.asyncIterator`
  well-known symbol already existed (M8).
- [x] M13-T050 **Interpreter — call dispatch + async-gen runtime (`src/interpreter.zig`)** — `[[Call]]`
  of `is_async && is_generator` → `createAsyncGenerator`; `yield` in an async-gen body =
  AsyncGeneratorYield (await operand, then yield); request-queue servicing (`asyncGeneratorResume` →
  `asyncGenDrainQueue` → `asyncGenHandleTransfer`), await-resume via the reaction Job
  (`asyncGenResumeAfterAwait`, routed in `runReactionJob`). State synced to `Generator.state` for
  `cleanupGenerators` (parked threads reaped at realm teardown — no hangs).
- [x] M13-T060 **Interpreter — `for await` eval + async iterator infra** — `getAsyncIterator`
  (Symbol.asyncIterator else AsyncFromSyncIterator wrap), `evalForAwaitOf` (await each `next()`, bind,
  run body, async-close on abrupt), `iteratorCallRaw`, `asyncIteratorClose`.
- [x] M13-T070 **Interpreter — AsyncFromSyncIterator (§27.1.4)** — `asyncFromSyncMethod`
  (next/return/throw promise-wrap; §27.1.4.4 continuation via `async_from_sync_wrap` onFulfilled).
- [x] M13-T080 **Interpreter — async `yield*` (§27.6.3.8)** — `doAsyncYieldDelegate` (delegate over the
  async iterator, await each inner step, re-yield).
- [x] M13-T090 **Tests (`src/engine.zig`)** — async-gen + for-await collecting `[1,2,3]`; `yield await
  p`; async-gen return value; for-await over a sync iterable of promises (AsyncFromSync); class `async
  *m(){}`; `.next()` returns a promise of `{value,done}`; `yield*` over an async iterable; `for await`
  SyntaxError outside async / non-of form. All green; no hangs.
- [x] **Conformance + regression hunt (harness, ReleaseFast):** full `language/` **passed 16,609 →
  19,924 (+3,315), 38.0% → 45.6%**; runner `--baseline` check: **"conformance: ok (no regression vs
  baseline)"** — 0 true regressions. Continuity `language/expressions` **8,320 → 9,728 (+1,408)**, 45.9%.
  Bench: reps=15 flagged loop_sum/str_build (machine contention from concurrent runs); the mandated
  reps=30/warmup=5 re-run is **"perf: ok (no ljs-vs-self regression)"** (+2–4% vs base, ljs 0.2–0.6×
  Node). No hangs (parked threads reaped at realm teardown; conformance wall-time ~+80s from per-test
  thread spawns across the ~3,300 newly-running async-gen/for-await tests — inherent to the M9 substrate).

**Result:** all gates green. Landed: async generators (§27.6) + `for await` (§14.7.5) +
AsyncFromSyncIterator (§27.1.4) + async `yield*` (§27.6.3.8) + async-gen methods. Nothing deferred.
</content>
