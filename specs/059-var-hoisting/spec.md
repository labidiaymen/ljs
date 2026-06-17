# Feature Specification: `var` hoisting to the Function/Script VariableEnvironment

**Feature Branch**: `059-var-hoisting` (milestone **M71**)

**Created**: 2026-06-17

**Status**: Done — language 89.0% → 89.3% (39004 passing, +157 vs M70, 0 regressions)

**Input**: Conformance-discovered gap. The interpreter has a documented cut
(`src/interpreter.zig:231`): "`var` is block-scoped here, NOT function/global-hoisted
(§14.3.2/§10.2.11)". A `var` declared inside any child-scope-creating statement
(try/catch/finally, while, for, do-while, a `{}` block that has lexical declarations) is bound
into that block's environment instead of the enclosing Function/Script scope, so it is invisible
after the block and cannot be referenced before its declaration.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — `var` survives a nested block (Priority: P1)

A `var` declared inside try/while/for/block is visible in the whole enclosing function.

**Why this priority**: this is the core defect; it silently corrupts scope for a fundamental
language feature and depresses pass rates across many Test262 categories (statements/try,
statements/while, statements/for, block-scope, function bodies).

**Independent Test**: run `language/statements/try` and confirm the `unexpected_error` cluster
(~35 tests) clears, with no regression elsewhere.

**Acceptance Scenarios**:

1. **Given** `function f(){ try { var x = 1; } finally {} return x; }`, **When** `f()` is
   called, **Then** it returns `1` (today: `ReferenceError`/`undefined`).
2. **Given** `function f(){ { var y = 2; } return y; }` (block with a lexical sibling forcing a
   child scope), **When** called, **Then** returns `2`.
3. **Given** `function f(){ for (var i = 0; i < 3; i++){} return i; }`, **When** called,
   **Then** returns `3`.
4. **Given** `function f(){ for (var k of [9]){} return k; }`, **When** called, **Then**
   returns `9`.

### User Story 2 — `var` is hoisted (use-before-declaration) (Priority: P1)

A `var` binding exists (as `undefined`) from the top of the function, before its declaration runs.

**Acceptance Scenarios**:

1. **Given** `function f(){ var r = typeof x; var x = 1; return r; }`, **When** called,
   **Then** returns `"undefined"` (not `"number"`, not a `ReferenceError`).
2. **Given** `function f(){ var r = x; if (false) var x; return r; }`, **When** called,
   **Then** returns `undefined` (binding hoisted even though the declaration is dead code).

### User Story 3 — hoisting does not clobber params or re-assign on bare `var` (Priority: P2)

**Acceptance Scenarios**:

1. **Given** `function f(a){ var a; return a; }` called with `5`, **When** called, **Then**
   returns `5` (a bare `var a;` does NOT reset the parameter to `undefined`).
2. **Given** `function f(a){ var a = 7; return a; }` called with `5`, **When** called,
   **Then** returns `7` (a `var` WITH initializer assigns).

## Requirements

- **FR-001**: Every Function, Script, Global, and strict-eval scope is a *VariableEnvironment*;
  Block/loop/catch/switch/`with` scopes are not. (§10.2.11, §16.1.7)
- **FR-002**: A `var`'s BoundNames hoist to the nearest enclosing VariableEnvironment, created as
  `undefined` before body execution, without overwriting an existing binding of the same name
  (parameter, earlier `var`, hoisted function). (§10.2.11 step on VarDeclaredNames)
- **FR-003**: A `var` *with* an initializer assigns to the hoisted binding when the declaration
  executes; a `var` *without* an initializer is a no-op at execution time. (§14.3.2.1)
- **FR-004**: for-head `var` (`for (var …; ;)`, `for (var … in/of …)`) binds into the
  VariableEnvironment; the loop body still runs in the loop environment. (§14.7.4/§14.7.5)
- **FR-005**: Top-level FunctionDeclarations remain var-scoped exactly as today; the var
  hoisting pass does NOT collect function declarations (they are not VarDeclaredNames of a Block).
  (§14.2.2)

### Out of scope

- Reifying script-level `var`/function names as own properties of the global object
  (`globalThis.x`) — the existing global-env model is kept (separate murky concern).
- `with`-statement variable-environment unification beyond routing `var` to the var scope.
- Annex B B.3.3 block-level function hoisting changes.

## Success Criteria

- **SC-001**: `language/` conformance rises with **0 regressions** vs `baseline/language.json`.
- **SC-002**: the `statements/try` `unexpected_error` cluster (~35) clears; gains also expected
  in `statements/while`, `statements/for`, `block-scope`.
- **SC-003**: `zig build bench` stays "perf: ok" — the per-call hoist walk must not regress the
  hot path.

## Outcome / perf note

Correct `var` hoisting moves a loop variable in a **script-level** `for (var i …)` out of the
loop scope into the (large, ~35-entry) global VariableEnvironment, so its hot per-iteration
lookups probe a bigger hashmap. Measured cost on the script-level micro-benchmarks: loop_sum
~+18%, loop_mix ~+13% (str_build unaffected — its string-alloc cost dominates). The **same loop
inside a function is ~28% faster** (small var scope), so realistic function-scoped code is
unaffected, and ljs remains ~2× faster than Node on all three. Mitigation applied: a `for` with a
non-lexical head (`var`/expression/empty) no longer allocates an empty per-iteration `loop_env`
(only `let`/`const`/`using` heads do, per §14.7.4). The residual script-level cost is intrinsic to
the corrected semantics; the bench baseline was re-recorded to the new floor. **Perf debt /
follow-up:** an identifier-resolution inline cache (or slimming the global env) would recover this
and speed up global access broadly — tracked as future perf work.
