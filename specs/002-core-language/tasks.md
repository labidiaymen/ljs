---
description: "Task list for M1 — core language runtime"
---

# Tasks: M1 — Core Language Runtime

**Input**: `specs/002-core-language/{spec,plan}.md`. **Cadence**: one cycle = one user story =
one commit (build+test+lint+bench green, parallel review, then gate). Data-model/quickstart are
folded into plan.md (Phase 0/1) for M1 to avoid over-producing artifacts.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Foundational (shared, lands inside Cycle A)
- [x] M1-T001 `Value.object` + `src/object.zig` (ordinary `[[Get]]`/`[[Set]]` + prototype walk) — done in Cycle C
- [x] M1-T002 `src/environment.zig` (Environment scope chain, `Binding{value,mutable,initialized}`, lookup) — §9
- [x] M1-T003 Extended `Completion` to `normal/throw/ret/brk/cont` — §6.2.4

## Phase A — US1 Bindings & statements (P1) 🎯  [Cycle A]
**Goal**: `var`/`let`/`const`, assignment, blocks, statement sequencing. **Test**: `ljs eval "var x=40; x+2"` → 42.
- [x] M1-T010 [US1] Lexer/parser: keywords `var/let/const`, `=`, `;`, `{ }` blocks, identifiers, statement & declaration grammar — §13/§14
- [x] M1-T011 [US1] Interpreter: declarations + assignment + block (lexical) scope; `const` reassignment → TypeError, unresolved → ReferenceError. (var = block-scoped + true TDZ = documented M1 cuts, later cycles)
- [x] M1-T012 [P] [US1] Binding tests (inline in `engine.zig`): var/let/const, reassignment, block scope, error cases — SC-001 slice

## Phase B — US2 Functions, calls & closures (P1)  [Cycle B]
**Goal**: function decl/expr, params, `return`, calls, closures, basic `this`. **Test**: `add(40,2)` → 42; closure captures.
- [x] M1-T020 [US2] Parser: `function` decl/expr, params, `return`, call postfix `f(args)`, `this` — §15
- [x] M1-T021 [US2] Function objects (kind `function`) holding AST body + captured env; `[[Call]]`; arity (missing → `undefined`); `return` completion; **closures**; basic `this` (method calls bind `this=receiver`); call-non-function → TypeError; runaway recursion → RangeError (depth guard)
- [x] M1-T022 [P] [US2] Function tests (inline in engine.zig): add, function expression, arity, closure capture, non-function TypeError, unbounded recursion → RangeError

## Phase C — US3 Objects & property access (P1)  [Cycle C]
**Goal**: object literals, `a.b`/`a[b]` read/write, prototype chain. **Test**: `var o={x:41}; o.x=o.x+1; o.x` → 42.
- [x] M1-T030 [US3] Parser: object literal `{k:v}`, member access (dot `a.b` + computed `a[e]`), assignment to member/index targets
- [x] M1-T031 [US3] Ordinary `[[Get]]`/`[[Set]]` + prototype walk (object.zig); access/set on null/undefined → TypeError. (Default `Object.prototype` + call-non-function TypeError land with Cycle B/E)
- [x] M1-T032 [P] [US3] Object tests (inline in engine.zig): literals, member/index r/w, member chain, null/undefined TypeError
- [x] M1-T033 [US3] **Recursion-depth guard**: deep expressions throw `RangeError` instead of segfaulting — surfaced by the perf gate (the 40× "regression" was a stack-overflow crash, not slow eval). Bench cases resized within the safe depth + re-baselined.

## Phase D — US4 Control flow & exceptions (P2)  [Cycle D]
**Goal**: `if/else`, `while`, `for`, `throw`/`try`/`catch`/`finally`. **Test**: `for` sum 0..9 → 45; throw caught.
- [ ] M1-T040 [US4] Parser: `if/else`, `while`, `for(;;)`, `throw`, `try/catch/finally`
- [ ] M1-T041 [US4] Interpreter: thread break/continue/return/throw completions; `try` runs matching `catch`, `finally` always runs — §14
- [ ] M1-T042 [P] [US4] `tests/controlflow_test.zig` (loops, if, throw/catch/finally ordering)

## Phase E — US5 Built-ins + harness execution (P2)  [Cycle E]
**Goal**: flip the real-suite number off zero. **Test**: `assert.js` loads; a real slice passes > 0.
- [ ] M1-T050 [US5] Read the vendored `harness/assert.js`+`sta.js` to enumerate the exact built-in surface needed
- [ ] M1-T051 [US5] `src/builtins.zig`: `Error` family (name/message), `Object`, basic `Array`, global env wiring — §20/§19
- [ ] M1-T052 [US5] Wire harness-include loading in `test262/runner.zig` (thread `io`, prepend sta.js+assert.js+includes for non-raw) — retires M0 T019, FR-007
- [ ] M1-T053 [US5] Tighten negative-runtime classification: compare thrown object `name` to `negative.type` (exact-type) — FR-008
- [ ] M1-T054 [US5] Run the target slice; record real baseline (pass > 0, SC-003); confirm M0 fixture sample still 27/6/2 and no perf regression

## Polish (final cycle)
- [ ] M1-T060 [P] Spec-clause comment audit on new modules; README + roadmap update (M1 done, real conformance %)
- [ ] M1-T061 [P] Leak check across new tests; determinism re-check

## Dependencies & parallelism
- Order by dependency: **Foundational (in Cycle A) → US1 → US3 → US2 → US4 → US5**. (Functions
  are objects, so objects/US3 land before functions/US2 in practice; cycles stay labeled per story.)
- **Agent fan-out per cycle**: within a cycle the failing test (`*_test.zig`) and any independent
  helper can be written by a parallel agent while the main thread does the interdependent
  parser+interpreter edits; integrate + `zig build`/`test`/`lint`/`bench` sequentially; then
  parallel review (correctness / spec-fidelity / Zig-idioms) before the gate.
- US5 is the convergence point (needs US1–US4) and is the cycle that raises conformance.

## Implementation Strategy
1. Cycle A (US1 + foundational) → bindings/statements work. 2. Cycle C (US3 objects).
3. Cycle B (US2 functions). 4. Cycle D (US4 control flow). 5. Cycle E (US5 built-ins+harness) →
**real conformance > 0**. Each cycle: green gates + review + commit, then the next.
