# Feature Specification: M1 — Core Language Runtime (run the harness, pass real tests)

**Feature Branch**: `002-core-language`

**Created**: 2026-06-15

**Status**: Draft

**Input**: User description: "M1: core language runtime (bindings, functions, objects, control flow, errors) to run Test262 harness helpers and pass a first real conformance slice"

## User Scenarios & Testing *(mandatory)*

> Users are the ljs engine developers / CI. M1's north star: turn the real-suite conformance
> number **off zero** by growing the engine until the Test262 harness helpers (`sta.js`,
> `assert.js`) execute and real positive tests can pass. This directly retires the M0 deferral
> (research D7) and wires harness-include loading (M0 T019).

### User Story 1 - Bindings & statements (Priority: P1)

Declare and use variables (`var`/`let`/`const`), assignment, and statement sequencing/blocks,
so programs are more than a single expression.

**Why this priority**: Everything else (functions, objects, harness helpers) needs bindings and
real statements. Foundational.

**Independent Test**: `ljs eval "var x = 40; x + 2"` → `42`; block scoping for `let`/`const`
behaves per spec on the curated cases.

**Acceptance Scenarios**:
1. **Given** `var x = 1; x = x + 2; x`, **When** evaluated, **Then** result is `3`.
2. **Given** `const c = 5; c = 6;`, **When** evaluated, **Then** a TypeError is thrown (assignment to constant).
3. **Given** a `{ let y = 1; }` block, **When** `y` is referenced outside, **Then** a ReferenceError.

### User Story 2 - Functions, calls & closures (Priority: P1)

Function declarations/expressions, parameters, `return`, calls, lexical closures, and a basic
`this`.

**Why this priority**: `assert.js` defines and calls functions; without calls there is no
harness and no real test passes.

**Independent Test**: `ljs eval "function add(a,b){return a+b} add(40,2)"` → `42`; a closure
captures its enclosing binding.

**Acceptance Scenarios**:
1. **Given** a function returning a value, **When** called, **Then** the return value is observable.
2. **Given** a closure over a binding, **When** called later, **Then** it sees the captured value.
3. **Given** a call with wrong arity, **When** evaluated, **Then** missing params are `undefined` (per spec).

### User Story 3 - Objects & property access (Priority: P1)

Object literals, member access (`a.b`, `a["b"]`), property assignment, and a basic prototype
chain with ordinary internal methods (`[[Get]]`/`[[Set]]`).

**Why this priority**: `assert` is a property of an object; comparisons read properties. Needed
for the harness.

**Independent Test**: `ljs eval "var o = {x: 41}; o.x = o.x + 1; o.x"` → `42`.

**Acceptance Scenarios**:
1. **Given** an object literal, **When** a property is read, **Then** its value is returned.
2. **Given** a missing property, **When** read, **Then** `undefined`.
3. **Given** a prototype with a property, **When** read on the child, **Then** it resolves up the chain.

### User Story 4 - Control flow & exceptions (Priority: P2)

`if`/`else`, `while`, `for`, and `throw` / `try`/`catch`/`finally`.

**Why this priority**: `assert.throws` needs `try/catch`; loops appear throughout the suite.
Also makes runtime-negative Test262 tests verifiable (real throws).

**Independent Test**: `ljs eval "var s=0; for (var i=0;i<10;i=i+1){s=s+i} s"` → `45`; a thrown
value is caught by `catch`.

**Acceptance Scenarios**:
1. **Given** a `throw`, **When** inside `try`, **Then** the matching `catch` runs and `finally` always runs.
2. **Given** a `while`/`for` loop, **When** evaluated, **Then** it iterates per spec.

### User Story 5 - Core built-ins & harness execution (Priority: P2)

The built-ins the harness needs: the `Error` family (`Error`, `TypeError`, `RangeError`, …) so
typed throws work, `Object`, a basic `Array`, and the globals `assert.js` references. Then wire
harness-include loading so `sta.js`+`assert.js`+`includes` run before each non-raw test.

**Why this priority**: This is what flips the real-suite number off zero and lets negative
runtime tests be classified by error *type* (tightening M0's approximation).

**Independent Test**: the harness loads `assert.js` without error and a chosen real Test262
slice reports a non-zero pass count.

**Acceptance Scenarios**:
1. **Given** the vendored suite + `--harness-dir`, **When** a positive test using `assert.sameValue` runs, **Then** it passes if the assertion holds.
2. **Given** a runtime-negative test expecting `TypeError`, **When** the engine throws a `TypeError`, **Then** the harness records pass (exact-type match, not just "threw").

### Edge Cases
- Recursion / deep call stacks → bounded by the step-cap watchdog (no host crash).
- `this` in sloppy vs strict mode; TDZ for `let`/`const`; assignment to `const`.
- Property access on `undefined`/`null` → TypeError.
- Calling a non-function → TypeError.

## Requirements *(mandatory)*

### Functional Requirements
- **FR-001**: Support `var`/`let`/`const` bindings with assignment; `const` reassignment and TDZ violations throw the spec error.
- **FR-002**: Support statements: expression, block (lexical scope), `if`/`else`, `while`, `for`, `return`, `throw`, `try`/`catch`/`finally`.
- **FR-003**: Support function declarations & expressions with parameters, `return`, calls, and lexical closures; basic `this` binding.
- **FR-004**: Support object literals, member access (dot + computed), property create/update, and an ordinary prototype chain via internal methods.
- **FR-005**: Provide the `Error` family as real objects with a `name`/`message`, so thrown errors carry a verifiable type.
- **FR-006**: Provide the core built-ins the Test262 harness helpers require (at minimum what `sta.js`/`assert.js` reference).
- **FR-007**: Load harness helpers (`sta.js`, `assert.js`) and declared `includes` before each non-`raw` test (retire the M0 T019 deferral); honor strict/sloppy.
- **FR-008**: Tighten negative-runtime classification to require the **expected error type** at the expected phase (replacing M0's "threw = pass" approximation).
- **FR-009**: The real-suite conformance number MUST be reported and MUST be **> 0** on a defined slice once US1–US5 land; no regression vs the recorded baseline (constitution gate).
- **FR-010**: All new evaluation carries inline ECMA-262 clause citations (Principle III); ljs-vs-Node perf must not regress (Principle IV).

### Key Entities
- **Environment Record** (declarative/object/function/global) — bindings + scope chain.
- **Reference Record** — base + referenced name, for assignment and member access.
- **Object** — properties (descriptors), `[[Prototype]]`, ordinary internal methods.
- **Function Object** — parameters, body, closure environment, `[[Call]]`.
- **Error objects** — the `Error` family with `name`/`message`.

## Success Criteria *(mandatory)*
- **SC-001**: A defined set of ≥30 core-language programs (bindings, functions, closures, objects, control flow, throw/catch) evaluate to spec-correct results (unit-tested).
- **SC-002**: The harness loads `sta.js`+`assert.js` without error and runs a real Test262 slice end-to-end.
- **SC-003**: On a defined real Test262 slice, ljs passes **> 0** tests and the pass count is recorded as a new baseline (the number goes up from M0's 0).
- **SC-004**: Negative-runtime tests are classified by exact error type; a wrong-type throw is recorded `fail (wrong_error)`.
- **SC-005**: No regression on the curated M0 fixture sample (still 27/6/2) and no ljs-vs-Node perf regression.
- **SC-006**: No memory leaks under the testing allocator across the new runtime; deep recursion is bounded by the step cap (no crash).

## Assumptions
- Tree-walk interpreter remains the execution tier (constitution IV); bytecode/JIT still deferred, graduated by benchmark data.
- "Core built-ins" is scoped to what the harness helpers actually use, not the full library; the rest grows in later milestones.
- Target slice for SC-003 is chosen during planning (likely `test/language/expressions/*` arithmetic/relational).
- A garbage collector is NOT introduced in M1; arena-per-realm is retained (objects live for the realm's lifetime). Revisit when memory pressure demands it.

## Dependencies
- M0 engine, harness, benchmark, and quality gates (complete).
- ECMA-262 (§9 environments, §10 ordinary objects, §13–§15 expressions/statements/functions, §20 Error).
- Vendored Test262 (`scripts/vendor-test262.sh`).
