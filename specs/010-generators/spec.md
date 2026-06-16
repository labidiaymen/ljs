# Feature Specification: M9 — Generators + `yield`

**Feature Branch**: `010-generators`

**Created**: 2026-06-16

**Status**: Cycle 1 in progress

**Input**: "M9: generators. M8 landed the §7.4 iterator protocol + a minimal Symbol, but only the
iterator *consumers* (for-of / spread / destructuring) and the native Array/String *producers*. The
language-level iterator producer — generator functions (`function*`) and the `yield` operator — was
explicitly deferred and is now the dominant remaining lever: `generators/*` (~469) + `yield/*` (~117)
plus the generator-method slice of `class`/`object` parse-errors. A tree-walking interpreter cannot
suspend its native stack mid-evaluation, so M9 runs each generator body on its own `std.Thread`,
alternating strictly with the consumer (ping-pong handoff: exactly one side runs at a time, so the
shared realm arena stays safe), and exposes the generator object as a conforming §27.5 iterator."

## Why (data-driven)

At M8 close the continuity gate (`language/expressions`, harness metric) is **6,825 / 40.2%**. M8 built
the §7.4 protocol but left the *producer* (`function*` / `yield`) unimplemented — `function*` and `yield`
parse-reject, so `generators/*` (~469 under `language/expressions`), `yield/*` (~813 references / ~117
direct), and the generator-method subset of `class`/`object` all fail at parse. Generators are the
single largest remaining lever; they are also the HARDEST cycle so far because the tree-walker recurses
on the native stack and cannot yield from arbitrary depth.

## Approach: thread-per-generator with strict ping-pong handoff

A recursive tree-walker can't suspend its native stack mid-evaluation. M9 runs each generator body on a
dedicated `std.Thread`, alternating strictly with the consumer via two binary handoffs — **only ONE
thread runs at a time**, which is what makes the shared realm arena safe (the handoff establishes
happens-before; the two sides never touch the arena concurrently). The handoff primitive is a
`std.Io.Semaphore` driven by the process-global `std.Io.Threaded.global_single_threaded` Io (its
`futexWait`/`futexWake` are raw-OS-futex, pool-independent — zero setup cost, no thread pool spun up).

- A **Generator object** (created when a `function*` is called) holds: the function (body + closure +
  this/home), a `state` (`suspended_start` / `suspended_yield` / `executing` / `completed`), a thread
  handle, two semaphores (`resume_gen`, `to_caller`), a transfer slot (`{ value, kind: yield|return|throw }`
  gen→caller + a `sent` Value caller→gen and a `resume_kind: next|return|throw`), and the realm pointers.
- `gen.next(v)`: `completed` → `{value:undefined, done:true}`; `suspended_start` → spawn the body thread
  (fresh per-generator Interpreter sharing arena+globals, `current_gen` set so `yield` reaches the
  handoff), `to_caller.wait()`, read slot; `suspended_yield` → store `v` as `sent` (resume_kind=next),
  `resume_gen.post()`, `to_caller.wait()`, read slot.
- The body thread: on `yield x` → slot=(yield, x), `to_caller.post()`, `resume_gen.wait()`; on resume the
  `yield` expression evaluates to `sent` (resume_kind=next), OR throws `sent` (resume_kind=throw), OR
  returns `sent` (resume_kind=return). On normal `return r` → slot=(return, r), completed,
  `to_caller.post()`. On an escaping throw → slot=(throw, err), completed, `to_caller.post()`.
- The caller reconstructs: yield→`{value:x, done:false}`; return→`{value:r, done:true}`; throw→re-throw.
- `gen.return(v)` (§27.5.1.4) / `gen.throw(e)` (§27.5.1.5): on a `suspended_start` generator return/throw
  directly (no body runs); on a `suspended_yield` generator, set resume_kind and resume the thread, so the
  parked `yield` performs a Return/Throw completion at the suspension point (propagating through any
  `try`/`finally` in the body).
- **`yield` in the interpreter:** `Interpreter.current_gen: ?*Generator`. `yield x` is only legal inside a
  generator body (SyntaxError otherwise, parse-phase). Evaluating `yield x` calls the current_gen handoff.
- **Generator object is iterable:** `%GeneratorPrototype%` carries `next`/`return`/`throw` and
  `[Symbol.iterator]()` returning `this`, so `for (x of gen())` and `[...gen()]` consume it via §7.4.

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Re-measure `language/expressions` (continuity gate — must not regress) and run
the mandatory before/after `mode+path` regression hunt (un-rejecting `function*` / `yield` turns
parse-negatives into runtime behavior; the §15.5 parse early errors must keep the genuine negatives
red). Stay bench-green: **threads are spawned ONLY for generators**; the ordinary call path is untouched.

### US1 — `function*` declaration + expression, generator object (§15.5, §27.5) (P1)
`function* g(){}` (declaration + expression; `*` after `function`) is parsed as a generator. Calling a
`function*` does NOT run the body — it returns a generator object (a §27.5 Generator) in
`suspended_start`. **Test**: `function* g(){} typeof g === "function"`; `var it = g(); typeof it ===
"object"`; the body does not run until `.next()`.

### US2 — `.next()` drives the body; `yield` produces values (§27.5.1.2, §15.5.5) (P1)
`it.next()` resumes the body to the next `yield` (or completion), returning `{value, done}`.
**Test**: `function* g(){ yield 1; yield 2 } var it = g(); it.next().value === 1; it.next().value === 2;
it.next().done === true`; a finite-sum generator; a generator that `return`s a value carries it on the
final `{value, done:true}`.

### US3 — `yield` receives the sent value (§15.5.5) (P1)
`yield` evaluates to the value passed to the *next* `.next(v)`. **Test**: `function* g(){ var x = yield;
return x } var it = g(); it.next(); it.next(5).value === 5`.

### US4 — generator is iterable: for-of + spread (§27.5.1.1, §7.4) (P1)
`%GeneratorPrototype%[Symbol.iterator]()` returns the generator, so it consumes through the M8 protocol.
**Test**: `[...g()]` spreads the yielded values; `for (const x of g()) …` iterates them; a destructuring
`var [a, b] = g()` pulls positionally.

### US5 — `.return()` / `.throw()` (§27.5.1.4 / §27.5.1.5) (P1, minimal acceptable)
`it.return(v)` finishes the generator early returning `{value:v, done:true}` (running `finally` blocks at
the suspension point); `it.throw(e)` injects a throw at the suspension point (caught by a body
`try/catch`, else propagates and completes the generator). On a `suspended_start` generator, `.return`/
`.throw` complete it without running the body. **Test**: `it.return(9)` → `{value:9, done:true}` and a
subsequent `.next()` is done; `it.throw` injected into a `try/catch` is observed; a `finally` runs on
`.return()`.

### US6 — parse early errors (§15.5.1) (P1)
`yield` outside a generator is a SyntaxError (a generator un-rejection must NOT silently accept `yield`
elsewhere). Inside a generator body, `yield` as a BindingIdentifier (param name, `var yield`) is a
SyntaxError. `yield*` (delegation) is parsed (Cycle 2 semantics) or rejected cleanly without breaking
`yield`. **Test**: `yield 1` at top level is a SyntaxError; `function* g(yield){}` is a SyntaxError;
`function* g(){ yield 1 }` parses.

### Edge Cases
- A generator never fully consumed leaves a parked body thread (blocked on `resume_gen`). Acceptable for
  the short-lived test harness; the interpreter joins/cleans up generators it can on run completion
  (best-effort), and a never-resumed thread is signaled to exit when the realm tears down.
- The recursion-depth guard / step-limit must still function on the generator thread (its Interpreter
  carries its own `depth`/`steps`, sharing the limits).
- `yield` has very low precedence (just above the comma/sequence operator, below assignment): `yield a +
  b` yields `a + b`; `x = yield y` assigns the sent value.
- Ordinary (non-generator) calls spawn NO thread and pay NO new overhead (bench gate).

## Requirements *(mandatory)*
- **FR-001** (US1): `ast.Function.is_generator` flag; `yield` expr node (`yield`, `yield expr`, `yield*
  expr`). Lexer detects `function` `*`; `yield` stays a contextual keyword.
- **FR-002** (US1/US6): parser generator context (`in_generator`); parse `function*` decl/expr; parse
  `yield`/`yield*` at the correct (very low) precedence inside a generator; SyntaxError for `yield`
  outside a generator and for `yield` as a BindingIdentifier inside one.
- **FR-003** (US1): `object.zig` Generator object + state enum + `FunctionData.is_generator`; calling a
  `function*` returns a generator object instead of running the body.
- **FR-004** (US2/US3/US5): `interpreter.zig` `current_gen`; the thread-per-generator handoff (spawn on
  first `.next`, ping-pong via `std.Io.Semaphore`); `yield` evaluates the handoff (returning `sent`,
  throwing on injected throw, returning on injected return); `%GeneratorPrototype%` `next`/`return`/`throw`.
- **FR-005** (US4): `%GeneratorPrototype%[Symbol.iterator]()` returns `this`; generators consume through
  the M8 §7.4 path (for-of / spread / destructuring) unchanged.
- **FR-006**: Spec-clause citations on every new node / field / op (§15.5 generator definitions, §27.5
  Generator objects, §27.5.3 %GeneratorPrototype%, §14.4 yield, §7.4 iterable wiring).
- **FR-007**: ordinary calls spawn NO thread (bench gate — no ljs-vs-self regression > 15%).
- **FR-008**: no net regression on the continuity gate; true regressions by `mode+path` 0 or far
  outweighed by recoveries; no HANGS (a deadlocked generator must not hang the conformance runner).

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `passed` (harness) ≥ the M8-close baseline of 6,825 (40.2%).
- **SC-002**: a `function*` returns a generator; `.next()` drives it; `yield` produces and receives
  values; the generator is iterable (for-of / spread); a returned value carries on the final result.
- **SC-003**: generator unit tests pass (`zig build test` exit 0).
- **SC-004**: M0–M8 tests still green; lint 0/0; bench green (ljs ≤ Node, ordinary calls unaffected); no
  net regression on the `mode+path` diff; no hangs.

## Assumptions
- Tree-walk tier retained. Suspension is via a dedicated OS thread per generator (`std.Thread`) with a
  strict ping-pong handoff (one runner at a time) over `std.Io.Semaphore` (the global threaded Io's
  raw-OS-futex). `yield*` delegation (§15.5.5), generator *methods* in classes/objects (`*m(){}`), and
  async generators are deferred to Cycle 2.
- A never-fully-consumed generator parks a thread (acceptable for the short-lived harness; documented).

## Dependencies
- M8 §7.4 iterator protocol + Symbol (`Symbol.iterator`, getIterator/iteratorStep, %…Prototype% install
  pattern), M5 functions/calls, M4 class/function-object/NativeId patterns. Test262 harness; bench gate.
  ECMA-262 §14.4, §15.5, §27.5, §7.4. Zig 0.16 `std.Thread`, `std.Io.Semaphore`,
  `std.Io.Threaded.global_single_threaded`.
