---
description: "Task list for M9 — generators + yield (§14.4 / §15.5 / §27.5, thread-per-generator ping-pong handoff, conformance-driven)"
---

# Tasks: M9 — Generators + `yield`

**Metric:** conformance reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`), same as M4–M8. The continuity gate is `language/expressions`; the committed
baseline `baseline/language-expressions.json` (M8 close: passed **6,825**, **40.2%**) is the floor.
Generators are the dominant remaining lever (`generators/*` ~469 + `yield/*` + the generator-method slice
of `class`/`object`).

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + **bench (ljs ≤ Node, no
thread on ordinary calls)** green). Re-measure `language/expressions` each cycle.

**Mandatory regression hunt (every cycle):** un-rejecting `function*` / `yield` turns parse-negatives into
runtime behavior — the §15.5.1 parse early errors must keep genuine negatives red. Capture per-test result
set (by `mode+path`) before/after (`git stash`, rebuild ReleaseFast, `comm`); true regressions 0 or far
outweighed by recoveries. **Watch for HANGS** (a deadlocked generator can hang the runner — fix before
commit).

## Cycle 1 — `function*` + `yield` + generator object (iterator) + `.next`/`.return`/`.throw` + for-of/spread (US1–US6) 🎯 (DONE — continuity gate (`language/expressions`, harness): passed 6,825 → **7,138** (+313), **0 true regressions / 313 recoveries** by `mode+path`; conformance 40.2% → **42.1%**. The recoveries are `generators/*` + the generator-shaped slice of `yield/*` / `for-of` / spread; the only initial regressions (19) were finer-grained §15.5.1/§14.4 parse early errors that previously passed only because the whole `function*`/`yield` construct parse-rejected wholesale — all 19 fixed by adding the precise early errors (`yield` as binding/identifier-reference inside a generator, `yield 3 + yield 4`, `yield\n*1`, generator UniqueFormalParameters, `(x=yield)=>{}`, `(yield)++`, `{yield}=…`), leaving 0. Bench green: `perf: ok (no ljs-vs-self regression)`, ljs 0.2–0.6× Node — ordinary calls spawn NO thread (the `is_generator` check is a single optional-field test before the depth bump). No hangs (the full run completes in ~45s; abandoned generators are unwound + joined at realm teardown). Committed baseline bumped 6,825 → 7,138.)
- [x] M9-T010 **AST — generator flag + yield node (`src/ast.zig`)** — `Function.is_generator: bool`; a
  `yield` expr node `yield: struct { argument: ?*const Node, delegate: bool }` (`yield`, `yield expr`,
  `yield* expr`). (§14.4 / §15.5)
- [x] M9-T020 **Lexer/Parser — `function*` + `yield` operator + early errors (`src/lexer.zig`,
  `src/parser.zig`)** — detect `function` `*` (the `*` already lexes as `.star`); a parser `in_generator`
  flag (saved/restored around every function body, set for `function*`); parse `yield` / `yield*` at the
  correct very-low precedence inside a generator body (just above comma, below assignment); §15.5.1 early
  errors: `yield` outside a generator is a SyntaxError, `yield` as a param/binding name inside a generator
  is a SyntaxError. `yield*` parsed (Cycle 2 semantics) without breaking `yield`.
- [x] M9-T030 **Object — Generator object + state + FunctionData.is_generator (`src/object.zig`)** — a
  `Generator` struct (function data, `state` enum `suspended_start`/`suspended_yield`/`executing`/
  `completed`, thread handle, two `std.Io.Semaphore`s, transfer slot `{value, kind}` + `sent` + resume
  kind, realm pointers); `Object.generator: ?*Generator` slot (null for ordinary objects);
  `FunctionData.is_generator`. (§27.5)
- [x] M9-T040 **Interpreter — calling `function*` returns a generator; the handoff; `yield`
  (`src/interpreter.zig`)** — `Interpreter.current_gen: ?*Generator`; calling a `function*` creates the
  generator object (proto = %GeneratorPrototype%) instead of running the body; the thread-per-generator
  ping-pong (spawn the body thread on first `.next` with a fresh Interpreter sharing arena+globals;
  alternate via the semaphores, one runner at a time); evaluating a `yield` node performs the handoff
  (yield value to caller; on resume return the `sent` value, OR throw / return per the injected resume
  kind). (§14.4 / §27.5.3.3)
- [x] M9-T050 **Interpreter/Builtins — %GeneratorPrototype% next/return/throw + [Symbol.iterator]
  (`src/interpreter.zig`, `src/builtins.zig`)** — install %GeneratorPrototype% with `next` (§27.5.1.2),
  `return` (§27.5.1.4), `throw` (§27.5.1.5), and `[Symbol.iterator]()` returning `this` (§27.5.1.1) so a
  generator consumes through the M8 §7.4 path (for-of / spread / destructuring). Thread lifecycle: join on
  completion; best-effort cleanup of abandoned generators on realm teardown (no hang in the runner).
- [x] M9-T060 **Tests (`src/engine.zig`, all green)** — `function* g(){yield 1; yield 2}` `.next()` →
  1, 2, done; `function* g(){var x=yield; return x}` sent value → 5; `[...g()]` spread; `for (x of g())`;
  finite-sum generator; generator returning a value (done=true carries it); `.return()`/`.throw()`
  minimal; `yield` outside a generator is a SyntaxError.
- [x] **Conformance + regression hunt (harness, ReleaseFast, `git stash` HEAD vs working-tree `comm`):**
  continuity gate `language/expressions` `passed ≥ 6,825`; 0 true regressions or far outweighed by
  recoveries; no hangs. Bench green (ordinary calls spawn no thread). Bump committed baseline.
- [x] **Landed:** `function*` declaration + expression; the `yield` operator (`yield` / `yield expr`,
  very-low precedence, sent-value on resume) with the §15.5.1/§14.4 parse early errors; the Generator
  object (thread-per-generator, strict ping-pong handoff over `std.Io.Semaphore` on the global threaded
  Io); `%GeneratorPrototype%` `.next` / `.return` / `.throw` (all three working: `.next` drives + sends;
  `.return(v)` finishes early running `finally`; `.throw(e)` injects at the suspension point, caught by a
  body `try/catch` else propagates); `[Symbol.iterator]()` → `this` so for-of / spread / array
  destructuring consume a generator through the M8 §7.4 path; a returned value carried on the final
  `{value, done:true}`; nested generators (an outer body thread driving an inner generator). **Deferred
  (Cycle 2):** `yield*` delegation (parsed, but Cycle 1 yields the operand as a single step — does NOT
  drain it; §15.5.5 forwarding deferred); generator *methods* in object literals (`{ *m(){} }`) and
  classes (`*m(){}` / `static *m(){}`) — still parse-reject (preserved negatives); the generator
  `.name`/`.length`; async generators. **Thread-lifecycle caveat:** a generator never fully consumed
  parks its body thread on `resume_gen`; at realm teardown `cleanupGenerators` sets `abandon`, wakes each
  parked thread (the `yield` then unwinds with a return completion so it cannot re-park inside a
  `finally`), and joins it — so no OS thread lingers and the short-lived conformance runner does not hang
  (verified: 200 abandoned generators + an infinite-loop abandoned generator both exit cleanly).

## Future cycles (planned)
- **Cycle 2 — `yield*` delegation (§15.5.5) + generator methods:** `yield* iterable` (delegate to an
  inner iterator, forwarding next/return/throw per §27.5.3.7); generator *methods* in object literals
  (`{ *m(){} }`) and classes (`*m(){}`, `static *m(){}`); the generator `.name`/`.length`.
- **Cycle 3+ — async generators / `for-await-of` / `AsyncGeneratorPrototype`** on the now-real generator
  substrate; `Map`/`Set`.

## Dependencies / order
T010→T020 (AST before parse) ; T030→T040 (object before the handoff) ; T040→T050 (handoff before the
prototype methods that drive it) ; T050→T060 (behavior before tests). The thread-per-generator handoff is
the substrate `yield*` (Cycle 2) and async generators (Cycle 3) sit on. Each cycle bench-gated (no thread
on ordinary calls) and runs the before/after `mode+path` regression hunt; watch for hangs.
