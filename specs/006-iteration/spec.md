# Feature Specification: M5 — Iteration Statements (for-in / for-of)

**Feature Branch**: `006-iteration`

**Created**: 2026-06-15

**Status**: Draft

**Input**: "M5: iteration statements — `for-in` / `for-of`. The single highest-leverage unblock: the
Test262 harness file `harness/propertyHelper.js` (pulled in by `verifyProperty`, which a HUGE number
of positive tests across the whole suite use) contains a `for (var x in obj)` loop the engine cannot
parse. Every test whose harness prelude includes propertyHelper.js therefore fails at the
harness-parse stage. Implementing `for-in` unblocks those positives at once; `for-of` unlocks the
iteration tests."

## Why (data-driven)
At M4 close, the largest *structural* drag on conformance is no longer a language feature gap but a
**harness-parse gap**: `vendor/test262/harness/propertyHelper.js` — the file behind `verifyProperty`,
which a large fraction of positive Test262 tests `$INCLUDE` — uses `for (var x in obj)` (line 153,
`isEnumerable`). The engine's parser rejects the `for (… in …)` header, so any test that includes
propertyHelper.js dies before its own body runs (a `parse_error` on the prelude, counted as a fail in
**both** modes). The M4 close note recorded this explicitly: the residual `class/*` `parse_error`
bucket "is blocked by `vendor/test262/harness/propertyHelper.js`, which uses a `for (… in …)` loop the
engine does not yet parse". M5 implements ECMA-262 §14.7.5 IterationStatement (for-in / for-of), the **parse
prerequisite** for that propertyHelper.js unblock. The continuity gate (`language/expressions`, harness
metric, baseline passed 6077 / 35.8%) MUST NOT regress (≥ 6077). NOTE (measured in Cycle 1): the for-in
parse fix clears propertyHelper.js's *parse* error, but the file then throws a *runtime*
`ReferenceError: Function` — it also needs `Function.prototype.call.bind`, `Object.defineProperty`,
`Object.getOwnPropertyDescriptor/Names`, `Object.prototype.hasOwnProperty/propertyIsEnumerable`, and
`Array.prototype.join/push`. So the full harness-prelude unblock requires a follow-on reflection
built-ins milestone; for-in/for-of is necessary but not sufficient. On its own it is conformance-NEUTRAL
on the vendored `language/expressions` subtree (0 regressions / 0 recoveries), and the direct
for-in/for-of statement subtrees are not in the local sparse checkout to measure directly.

## User Scenarios & Testing *(mandatory)*
Users: engine devs / CI. Each cycle adds a coherent slice of §14.7.5, re-measures `language/expressions`
conformance (the continuity gate — must not regress; propertyHelper.js positives recover only once the
follow-on reflection built-ins also land), reports the direct `statements/for-in` + `statements/for-of`
subtree gains (before→after) when those subtrees are vendored, runs the mandatory before/after
regression hunt by `mode+path` (un-rejecting `for (… in/of …)` converts parse-negatives into
reachable-runtime tests — true regressions must be 0 or far outweighed), and stays bench-green (ljs ≤
Node; for-in/for-of are new statement paths, not on the
existing loop benches).

### US1 — `for (LHS in obj)` enumerates property names (P1)
`for (LHS in obj) Stmt` (§14.7.5) visits the **enumerable string-keyed** property names of `obj` and
its prototype chain, each name once (shadowed/duplicate names skipped). `LHS` may be a `var`/`let`/
`const` declaration of a single binding, or an existing assignment target (identifier / member `a.b` /
index `a[k]`). A `null`/`undefined` operand → the body never runs (no throw, §14.7.5.6 step 7.a).
M-subset enumeration: own enumerable string keys + inherited enumerable string keys, shadowed names
skipped; for an Array, the integer indices ARE enumerable but `length` is NOT.
**Test**: `var s=''; for (var k in {a:1,b:2}) s+=k; s` → `"ab"`; for-in over `['x','y']` yields the
index strings `"0"`,`"1"` (NOT `"length"`); for-in skips an inherited non-enumerable / a shadowed name;
`for (var x in null) …` and `for (var x in undefined) …` run the body zero times.

### US2 — `for (LHS of iterable)` iterates values (P1)
`for (LHS of iterable) Stmt` (§14.7.5) iterates the **values** of `iterable`. Reusing the engine's
existing spread/array-pattern iteration model (`evalSpreadList` / `iterableToSlice`): an Array iterates
its elements; a String iterates its characters. `LHS` forms are the same as for-in. A non-iterable
operand (including `null`/`undefined`, a number, a plain object with no iterator) → **TypeError**
(§14.7.5.6 → GetIterator throws). A full `Symbol.iterator` iterator protocol is deferred to a later
cycle (Symbol does not yet exist in the engine); Array/String (and the `arguments` array) are
special-cased this cycle and the gap is noted.
**Test**: `var t=0; for (var v of [1,2,3]) t+=v; t` → `6`; `var s=''; for (var c of 'ab') s+=c; s` →
`"ab"`; `for (var x of 5) …` → TypeError; `for (var x of {}) …` → TypeError.

### US3 — `break` / `continue` and per-iteration binding scope (P1)
Both statements support `break` and `continue` via the existing Completion machinery (the `.brk`/`.cont`
records already handled by `while`/`for`). A `let`/`const` for-in/of head creates a **fresh binding per
iteration** (§14.7.5.7 ForIn/OfBodyEvaluation CreatePerIterationEnvironment), matching how the existing
`for (let …; …; …)` statement scopes its bindings; a `var` head writes to the enclosing variable.
**Test**: `break` after the first match in both statements; `continue` skipping the accumulation in
both; a `let` per-iteration head doesn't leak across iterations.

### Edge Cases
- `for (var x in y)` vs the C-style `for (var x = 0; …)` — the parser must NOT treat the `in` operator
  inside the for-header's first binding/expression as the relational `in` (the `[~In]` grammar): after
  the first declaration/LHS, `in`/`of` means for-in/for-of.
- `for ((a in b);;)` is a C-style `for` whose init is the `in` *expression* `(a in b)` — the
  parenthesized `in` is a normal relational operator, NOT a for-in header.
- A for-in head that is a `var`/`let`/`const` binding takes a single binding with NO initializer
  (`for (var x = 1 in y)` is a §14.7.5.1 Early Error in strict; the sloppy `var x = 1 in y` annex-B
  legacy form is out of M-subset scope and rejected).
- for-in/of over an empty operand (`{}` / `[]` / `''`) runs the body zero times (no throw for in;
  zero iterations for of).

## Requirements *(mandatory)*
- **FR-001**: Parse `for ( ( var | let | const )? ForBinding ( in | of ) Expression ) Statement` as both
  for-in and for-of, branching from the existing `parseFor`. `of` is contextual (lexed as an
  identifier with lexeme `"of"`, recognized only in the for-header position); `in` is the `kw_in`
  keyword. The first binding/LHS is parsed with the relational `in` suppressed (`[~In]`) so
  `for (a in b)` is a for-in head, while `for ((a in b);;)` (a parenthesized `in`) is a C-style for.
- **FR-002**: AST — new `Stmt.for_in_stmt` and `Stmt.for_of_stmt`, each carrying the loop head
  (a declaration kind + single binding pattern, OR an assignment-target expression node), the operand
  expression, and the body statement.
- **FR-003** (US1): §14.7.5 for-in evaluation — `EnumerateObjectProperties`: visit the enumerable
  string-keyed own + inherited property names of the operand, each name once (skip a name already
  visited / shadowed lower on the chain); skip Array `length`; `null`/`undefined` operand → zero
  iterations, no throw. Bind/assign each name (a string) to the LHS, run the body.
- **FR-004** (US2): §14.7.5 for-of evaluation — iterate the operand's values via the existing
  Array/String iteration model (`iterableToSlice`); a non-iterable operand → TypeError. Bind/assign
  each value to the LHS, run the body.
- **FR-005** (US3): `break`/`continue` honored (the `.brk`/`.cont` Completion pattern of `while`/`for`);
  a `let`/`const` head gets a fresh per-iteration binding scope, a `var` head writes the enclosing var.
- **FR-006**: Spec-clause citations on every new production / abstract operation (Principle III):
  §14.7.5 ForIn/ForOfStatement, ForIn/OfHeadEvaluation, ForIn/OfBodyEvaluation, EnumerateObjectProperties.
- **FR-007**: ljs ≤ Node on the bench (absolute pre-commit gate); no M0/M1/M2/M3/M4 regression (the new
  for-in/of paths are off the existing hot loop benches).
- **FR-008**: Un-rejecting `for (… in/of …)` must NOT net-regress on the continuity gate
  (`language/expressions`, harness metric): true regressions by `mode+path` must be 0 or far
  outweighed by recoveries. Net gain expected (the propertyHelper.js unblock). The C-style
  `for ((a in b);;)` and other `[In]`-grammar cases must continue to parse correctly.

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `passed` (harness metric) does not regress below the M4-close
  baseline of 6077 (35.8%). [Cycle 1 result: exactly 6077 — conformance-neutral; the propertyHelper.js
  prerequisite is cleared at the parse layer but its runtime requires the reflection built-ins, a
  follow-on milestone, so no positives recover yet on this vendored subtree.]
- **SC-002**: The direct subtrees `language/statements/for-in` and `language/statements/for-of` improve
  before→after when vendored. [Cycle 1: not in the local sparse checkout — only `language/expressions`
  is vendored — so unmeasurable locally; verified by 18 in-repo unit tests instead, see SC-003.]
- **SC-003**: ≥7 for-in/for-of unit tests pass (`zig build test` exit 0): for-in over an object →
  ordered keys; for-in over an array → index strings, no `length`; for-in skips inherited/shadowed;
  for-of over an array sums; for-of over a string concatenates; `break`/`continue` in both; for-of
  over a non-iterable throws.
- **SC-004**: M0–M4 tests still green; bench green (ljs ≤ Node); no leaks under the testing allocator;
  no net regression on the `mode+path` diff (FR-008).

## Assumptions
- Tree-walk tier retained; this is parser + evaluator work reusing the existing object model
  (`Object.properties` map + prototype chain for in-enumeration; `iterableToSlice` for of-iteration).
- Property enumeration order: the M-subset uses the `StringHashMapUnmanaged` key-iteration order for an
  object's own string keys and walks the prototype chain outward, de-duplicating visited names. Integer
  array indices are enumerated in numeric order (they are not stored in the property map — arrays use
  `.elements`). Strict spec enumeration ordering (integer keys ascending, then string keys in insertion
  order, per OrdinaryOwnPropertyKeys §10.1.11.1) is NOT guaranteed for non-array own string keys unless
  tests demand it (deferred to a later cycle).
- The general `Symbol.iterator` iterator protocol, generator iterables, `Map`/`Set`, async iteration
  (`for await`), labeled iteration statements, and destructuring-pattern for-in/of heads beyond a single
  identifier/member/index are deferred to later cycles. Array, String, and the `arguments` array are the
  iterables supported in Cycle 1.

## Dependencies
- M1 engine (statements, `var`/`let`/`const`, `break`/`continue`, Completion records, environment
  scoping), M2 arrays/strings (`Object.elements`, the String iteration model), M3 parser/syntax
  (assignment targets, patterns), M4 (object model). Test262 harness; bench gate. ECMA-262 §14.7.5.
