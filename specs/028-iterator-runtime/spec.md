# M28 — Iterator-protocol runtime

## Context
The iterator bucket — `statements/for-of` (~626 fail) + `statements/for-await-of`
(~562) + `expressions/async-generator` (~292) — was assumed to fail at RUNTIME
(§7.4 iteration-protocol edge cases), since for-of / for-await / async-generators are
already implemented (M5/M8/M13). Diagnosis showed the OPPOSITE: the dominant cause is
parse-phase, in the destructuring grammar shared by these test families. This milestone
fixes the highest-impact parse-level causes with 0 regressions vs `baseline/language.json`.

## Diagnosis (HEAD 3c439b2, language passed=33083, 75.8%)
Failure histogram over the three target dirs:
- `parse_error` 1048 (553 unique files — **543 of them `dstr/*`**) — DOMINANT
- `unexpected_error` 574 (298 unique)
- `no_error_expected_throw` 10

The `dstr/*` parse failures decompose into three independent grammar gaps, each
reproduced minimally OUTSIDE of for-of (so the fixes are general, not loop-specific):

1. **DestructuringAssignment pattern in the for-of/for-in HEAD.** `for ([a, b] of …)`
   and `for ({a} of …)` — an ArrayLiteral / ObjectLiteral LeftHandSideExpression head
   (the §13.15.5 cover grammar, no `var`/`let`/`const`) was rejected by the parser's
   `isSimpleAssignTarget` gate. Affected ~490 (for-of) + most of the assignment-form
   for-await-of `dstr` files.
   - `for ([v2 = 10] of [[2]]) {}` → SyntaxError (expected: `v2 === 2`).

2. **Object BINDING-pattern computed / numeric / string PropertyNames.** `var { [k]: x }`,
   `var { 0: v }`, and the nested-rest form `var [...{ 0: v, length: z }]` — the binding
   pattern parser only accepted identifier / string keys (`{ [expr]: … }` and `{ 0: … }`
   were SyntaxErrors). The `ObjectBindingProperty` AST node had no computed-key field
   (deferred at the object-literal-computed-key milestone). Affected the `*-obj-ptrn-prop-eval-err`
   and `*-ary-ptrn-rest-obj-prop-id` families across all of var/let/const for-of/for-await.
   - `for (var { [thrower()]: x } of [{}]) {}` → SyntaxError (expected: thrower's error).

3. **Parenthesized inner default clobbering the cover-grammar refinement** (latent bug,
   surfaced by #1). `[a = (1)] = []` and `for ([a = (1)] of …)` were rejected: the
   `!last_was_paren` heuristic that distinguishes the AssignmentPattern cover grammar from
   a ParenthesizedExpression target (`({a}) = x`) was reading the flag left set by the
   parenthesized *default* `(1)` inside the literal, not by the literal itself.

A residual `parse_error` tail is genuinely out of scope for this milestone: regex
literals (`/re/` — RegExp built-in not implemented), `using` declarations (explicit
resource management, a separate proposal), and string code-point iteration (the engine's
strings are UTF-8-byte-based, a string-internals milestone).

## Root cause #1 (FIXED) — for-head AssignmentPattern
`parseFor`'s expression-head branch (`src/parser.zig`) rejected any non-simple target.
Fix: when the head is an un-parenthesized ArrayLiteral / ObjectLiteral followed by
`of`/`in`, refine it via `validateAssignmentPattern` (the existing §13.15.1 refinement,
which also discharges CoverInitializedName / duplicate-`__proto__` obligations) instead of
rejecting — mirroring the plain-`=` DestructuringAssignment path. The interpreter's
`bindForHead` (`src/interpreter.zig`) routes an `array_literal`/`object_literal` head
through the existing `assignPattern` (§13.15.5.2 DestructuringAssignmentEvaluation), which
already implements §7.4.11 IteratorClose on an abrupt element/default. Simple targets keep
the PutValue path.

## Root cause #2 (FIXED) — computed / numeric binding-pattern keys
`ObjectBindingProperty` gained an optional `computed: ?*const Node` field (`src/ast.zig`).
`parseObjectPattern` (`src/parser.zig`) now reuses `parsePropertyName` for the key, so
identifier / string / numeric / `[computed]` / keyword names all parse; a string / numeric
/ computed name without a `:` is a SyntaxError (no shorthand form). `bindPattern`'s object
branch (`src/interpreter.zig`) evaluates a computed key once (in source order, ToPropertyKey
→ string or Symbol), reads via `getPropertyV`, and — when a BindingRestProperty is present —
records the resolved string key so the rest copy excludes it.

## Root cause #3 (FIXED) — parenthesized inner default
`parseArrayLiteral` / `parseObjectLiteral` (`src/parser.zig`) now clear `last_was_paren`
after the closing `]`/`}`: the literal itself is not a ParenthesizedExpression, so a
parenthesized inner value/default must not poison the cover-grammar refinement. A genuinely
parenthesized literal target (`({a}) = x`) is still rejected — the outer paren re-sets the
flag after the inner literal clears it.

## Harness fix (enabling the gate)
`test262/report.zig` `regressionsVs` was O(baseline × results) with an `allocPrint` per
comparison — at the full-`language/` corpus (≈34k × 44k) this OOM-killed (SIGKILL 137)
before the regression verdict printed. Replaced with a one-shot passing-id `StringHashMap`
→ O(results + baseline). Semantically identical; no change to the verdict.

## Scope / deviations
- Pure ECMAScript (§7.4, §13.15.5, §14.3.3, §14.7.5); no host APIs.
- Out of scope (residual tail): regex literals, `using` declarations, string code-point
  iteration (UTF-8-byte string model).

## Result
language: passed 33083 → 34177 (75.8% → 78.3%), +1094, 0 regressions. Bench: perf ok,
ljs ≤ Node.
