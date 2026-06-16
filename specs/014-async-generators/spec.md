# Feature Specification: M13 — Async Generators + `for await`

**Feature Branch**: `014-async-generators`

**Created**: 2026-06-16

**Status**: Cycle 1 DONE — full `language/` 38.0% → 45.6% (passed 16,609 → 19,924, +3,315; 0 true
regressions); `language/expressions` 8,320 → 9,728. Landed: async generators + `for await` +
AsyncFromSyncIterator + async `yield*` + async-gen methods.

**Input**: "M13: async generators + `for-await-of`. M9 built the generator thread substrate
(thread-per-generator, ping-pong handoff, `.next/.return/.throw`, %GeneratorPrototype%); M11 built
the Promise + microtask/Job runtime and async functions (threaded body suspending at each `await`).
`async function*` was routed through the PLAIN-async path (body runs, no async-gen surface). This
milestone gives async generators their real §27.6 surface, adds `for await (… of …)` (§14.7.5), and
AsyncFromSyncIterator (§27.1.4). Combined this is the largest remaining lever: `for-await-of` (~2253)
+ `async-generator` (~1570) + the async-gen-method slices of class/object."

## Why (data-driven)

At M12 close the full `language/` tree is **passed 16,609 / 38.0%** (harness metric);
`language/expressions` is **8,320**. `async function*` produced a value via the plain-async path (the
body ran but `yield` had no async-generator surface, so calling one and consuming it failed); `for
await` parse-errored entirely; AsyncFromSyncIterator did not exist. These are the dominant remaining
clusters of failing tests.

## Approach: reuse the M9 generator thread + the M11 Promise/Job runtime

An async generator body runs on the SAME `std.Thread` substrate as a sync generator / async function.
The body can suspend in TWO ways, both via the existing `doYieldRaw` ping-pong handoff (carry a value
out, park on `resume_gen`):

- **`await x`** (§27.6.3.8 AsyncGeneratorAwait, also inside `yield`) — PromiseResolve(x), register
  internal fulfill/reject reactions that resume the body. Identical to async-function `await`.
- **`yield x`** (§27.6.3.x AsyncGeneratorYield) — FIRST `await x` (so a thenable operand is adopted),
  then resolve the *current request*'s promise with `{value:x, done:false}` and suspend until the next
  request is serviced.

A new `AsyncGenerator` state (on `Object.async_generator`) holds the underlying `Generator` (thread +
handoff), an `AsyncGeneratorState` (`suspended_start`/`suspended_yield`/`executing`/`awaiting_return`/
`completed`), and a **request queue** (§27.6.3.1): each `.next/.return/.throw` enqueues a request
returning a fresh promise; `AsyncGeneratorDrainQueue` services them one at a time. The transfer carries
a discriminator (await-suspension vs yield-suspension vs terminal) so the servicing loop knows whether
to register reactions (await) or settle the current request (yield/done).

`for await (lhs of iterable) body` (§14.7.5): GetIterator(iterable, async) — use
`iterable[Symbol.asyncIterator]()` if present, else wrap the sync iterator in an **AsyncFromSyncIterator**
(§27.1.4) whose `.next` promise-wraps + awaits each sync `{value,done}`. Each iteration: `await
iterator.next()`, run the body; an abrupt completion closes the iterator (await `return`). Only valid in
an async context (parser SyntaxError otherwise) — tracked via the existing `in_async` flag; `await`
after `for` with no LineTerminator.

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Re-measure the full `language/` tree (PRIMARY) + `language/expressions`
(continuity) and run the mandatory before/after `mode+path` regression hunt. Stay bench-green: the
ordinary, sync-generator, and plain-async call paths are UNCHANGED (async-gen is a new branch keyed on
`is_async && is_generator`).

### US1 — `async function*` returns an AsyncGenerator (§27.6) (P1)
Calling an `async function*` returns an AsyncGenerator object (proto %AsyncGeneratorPrototype%), body
not yet run. `.next()` returns a Promise of `{value, done}`.

### US2 — `.next/.return/.throw` return promises; request queue (§27.6.3) (P1)
Each call returns a promise; requests serviced one at a time (FIFO). `yield x` resolves the pending
next-promise with `{value:x, done:false}`; completion resolves with `{value, done:true}`; an uncaught
throw rejects. `yield await p` works (await inside the body).

### US3 — `for await (x of asyncIterable) body` (§14.7.5) (P1)
Inside an async function / async generator, `for await` drives an async iterator: each step awaits
`iterator.next()`, awaits the value, runs the body. Consuming an async generator with `for await`
collects its values in order.

### US4 — AsyncFromSyncIterator (§27.1.4) (P1)
`for await (x of [Promise.resolve(1), 2])` — a SYNC iterable (no `[Symbol.asyncIterator]`) is wrapped:
each sync `{value, done}` is promise-wrapped and the value awaited, so a sync iterable of promises is
consumed as if async.

### US5 — async-generator methods (§15.6) (P1)
`class C { async *m(){} }`, `static async *m(){}`, `{ async *m(){} }`, computed — produce async
generators (the parser already sets `is_async`+`is_generator`; wire the call path).

### US6 — `yield*` over an async iterable (§27.6.3) (P2, may defer)
`yield* asyncIterable` in an async generator delegates, awaiting each inner step.

### Edge Cases
- `for await` outside an async context is a SyntaxError (parse-phase).
- NO HANGS: the request-queue servicing terminates; the microtask/Job drain is step-bounded; a
  never-consumed async generator parks a thread reaped at realm teardown (reuses `cleanupGenerators`).
- An async generator that is never driven leaves its body unspawned (lazy, like a sync generator).

## Requirements *(mandatory)*
- **FR-001** (US1/US5): calling an `is_async && is_generator` function returns an AsyncGenerator (new
  branch in [[Call]], before the plain-async branch).
- **FR-002** (US1/US2): `object.AsyncGenerator` state + request queue; %AsyncGeneratorPrototype% with
  `next`/`return`/`throw` (each returns a promise) + `[Symbol.asyncIterator]()` returns this.
- **FR-003** (US2): `yield` in an async-generator body = AsyncGeneratorYield (await operand, then settle
  the current request); `await` reuses the async-function handoff; the servicing loop distinguishes
  await-suspension from yield-suspension from terminal via a transfer discriminator.
- **FR-004** (US3): `for await` parse (async-context check, `await` after `for`) + eval (GetIterator
  async hint, await each step, close on abrupt).
- **FR-005** (US4): AsyncFromSyncIterator (§27.1.4) — wrap a sync iterator; its `.next/.return/.throw`
  promise-wrap + await the sync result.
- **FR-006**: Spec-clause citations on every new node/field/op.
- **FR-007**: ordinary / sync-gen / plain-async paths unchanged (bench gate).
- **FR-008**: no net regression on the full `language/` tree; no HANGS.

## Success Criteria *(mandatory)*
- **SC-001**: full `language/` `passed` ≥ 16,609; large gain expected.
- **SC-002**: `language/expressions` ≥ 8,320.
- **SC-003**: async-generator + for-await unit tests pass (`zig build test` exit 0).
- **SC-004**: lint 0/0; bench green (ljs ≤ Node, ordinary/sync-gen/plain-async unaffected); no net
  `mode+path` regression; no hangs.

## Assumptions
- Tree-walk tier retained; suspension via the M9 thread substrate; Promise/Job runtime from M11.
- `yield*` over an async iterable may be deferred to a follow-up cycle if needed for a stable green.

## Dependencies
- M9 generator substrate (`Generator`, `current_gen`, ping-pong handoff, teardown). M11 Promise/Job
  runtime (`PromiseData`, `Job`, `enqueueJob`/`drainJobs`, async-fn `await`). M8 §7.4 iterator protocol
  + Symbol (`Symbol.iterator`/`Symbol.asyncIterator` well-known). ECMA-262 §27.6, §14.7.5, §27.1.4.
</content>
</invoke>
