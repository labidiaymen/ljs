---
description: "Task list for M5 — iteration statements (for-in / for-of, §14.7.5, conformance-driven)"
---

# Tasks: M5 — Iteration Statements (for-in / for-of)

**Metric:** conformance is reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`, the standard Test262 way), same as M4. The continuity gate is
`language/expressions`; the committed baseline `baseline/language-expressions.json` (M4 close:
passed **6077**, **35.8%**) is the floor — M5 must push it UP (the propertyHelper.js unblock).

**Cadence**: one cycle = one coherent slice of §14.7.5 = one commit (build + test + lint + **bench
(ljs ≤ Node)** green). Re-measure `language/expressions` (continuity gate) AND the
`language/statements/for-in` + `language/statements/for-of` subtrees (direct gains) each cycle.

**Mandatory regression hunt (every cycle):** un-rejecting `for (… in/of …)` converts parse-negative
tests into reachable-runtime tests, and un-blocks every test whose harness prelude includes
`propertyHelper.js`. Capture the per-test result (by `mode+path`) before and after each change
(`git stash` the worktree, rebuild ReleaseFast, measure, `comm`); true-regressions must be 0 or far
outweighed by recoveries. Do NOT commit a net regression on the continuity gate.

## Cycle 1 — for-in + for-of statements (US1 + US2 + US3) 🎯 (DONE — continuity gate (`language/expressions`, harness): passed 6077 → 6077, +0 net, **0 true regressions / 0 recoveries** by `mode+path`; conformance 35.8% → 35.8%. The for-in/for-of statement subtrees are NOT in the vendored checkout — only `language/expressions` is vendored — so the *direct* subtree gain is unmeasurable locally; the propertyHelper.js prerequisite is now half-cleared, see below)
- [x] M5-T010 **Parse `for (… in/of …)`** — extend `parseFor` to detect `in`/`of` after the first
  ForBinding / LHS and branch to for-in / for-of (the C-style `for(init; test; update)` path is
  unchanged when neither is seen). `of` is contextual (lexed `.identifier` lexeme `"of"`); `in` is
  `kw_in`. The first binding/LHS is parsed with the relational `in` suppressed (the `[~In]` grammar)
  via a new `no_in` parser flag honored in `parseExprFrom` (skips `kw_in` at the relational level), so
  `for (a in b)` is a for-in head while `for ((a in b);;)` (a *parenthesized* `in`, parsed with `no_in`
  off inside the parens) stays a C-style `for`. Declaration heads (`var`/`let`/`const`) parse exactly
  one binding with no initializer; an existing assignment target (identifier / `a.b` / `a[k]`) is
  parsed via the expression path and validated as a simple assignment target.
  - **AST (`src/ast.zig`):** new `Stmt.for_in_stmt` / `Stmt.for_of_stmt`, each
    `{ head: ForHead, right: *const Node, body: *const Stmt }`; `ForHead` is a union of
    `{ decl: { kind: DeclKind, target: *const Pattern } }` (a declared single binding) and
    `{ target: *const Node }` (an existing assignment-target expression node — identifier / member /
    index).
  - **Parser (`src/parser.zig`):** `parseFor` rework — after `(`, the three init shapes branch:
    (a) `;` → C-style; (b) `var`/`let`/`const` → parse one ForBinding with `no_in` on, then peek
    `kw_in`/`of` (for-in/of) vs `=`/`,`/`;` (C-style declaration — fall back to the multi-declarator
    `parseDecl`-style loop); (c) an expression → parse one LHS with `no_in` on, then peek `kw_in`/`of`
    (validate the LHS is a simple assignment target) vs continue the C-style init expression. The
    `no_in` flag is threaded through the first-clause parse only.
  - **Interpreter (`src/interpreter.zig`):** `for_in_stmt` — §14.7.5 ForIn/OfHeadEvaluation
    (`enumerate` branch): a `null`/`undefined` operand runs the body zero times (no throw); otherwise
    `EnumerateObjectProperties` collects the enumerable string-keyed names of the operand + its
    prototype chain (each name once; shadowed/duplicate skipped; Array `length` skipped; Array integer
    indices in numeric order, then own/inherited string keys via the property map). `for_of_stmt` —
    §14.7.5 ForIn/OfHeadEvaluation (`iterate` branch) reuses `iterableToSlice` (Array elements / String
    chars); a non-iterable operand (incl. `null`/`undefined`/number/plain object) → **TypeError**.
    Both: §14.7.5.7 ForIn/OfBodyEvaluation binds/assigns each item to the head (a `let`/`const` head
    gets a fresh per-iteration `Environment`; a `var`/assignment head writes the enclosing target via
    a shared `bindForHead` that handles a declared pattern vs an assignment target), runs the body, and
    honors the `.brk`/`.cont` Completion records exactly like `while`/`for`.
  - **Tests (`src/engine.zig`, 4 new test blocks, all green):** for-in single-key exact name + multi-key
    count + array index strings (`"012"`, no `"length"`, no `Array.prototype` methods) + inherited
    user-proto key + shadowing-visited-once + empty obj/array + `for (var x in null/undefined)` zero
    iterations; for-of array sum (`6`) + string concat (`"abc"`) + empty + non-iterable (`5`/`{}`/`null`/
    `undefined`/`true`) → TypeError; `break`/`continue` in both; `let` per-iteration closure capture
    (`"abc"`); assignment-target heads (identifier / `o.k` / `a[j]`); `[~In]` disambiguation
    (`for (('x' in b); …)` C-style, `a['t' in o ? 0 : 1]` subscript); multi-declarator C-style for.
  - **Conformance + regression hunt (harness metric, ReleaseFast, `comm` of the `--update-baseline`
    pass-id sets):** continuity gate `language/expressions` `passed 6077 → 6077`, conformance 35.8% →
    35.8% — **0 true regressions AND 0 recoveries** by `mode+path`. The change is exactly
    conformance-NEUTRAL on the vendored subtree. **Honest finding on the expected propertyHelper.js
    unblock:** `for (var x in obj)` now PARSES (propertyHelper.js no longer dies at the prelude
    SyntaxError — the parse prerequisite is cleared), but propertyHelper.js still throws a RUNTIME
    `ReferenceError: Function` at its module top (lines 31–34 use `Function.prototype.call.bind`,
    `Object.defineProperty/getOwnPropertyDescriptor/getOwnPropertyNames`,
    `Object.prototype.hasOwnProperty/propertyIsEnumerable`, `Array.prototype.join/push` — none of which
    this engine implements yet). So the harness-prelude unblock is only HALF done: for-in was necessary
    but not sufficient; the remaining blocker is a `Function`/`Object.defineProperty`/reflection
    built-ins milestone (out of M5 scope). The direct `statements/for-in` + `statements/for-of` subtrees
    are NOT in the local sparse checkout (`vendor/test262/test/language` contains only `expressions/`),
    so their gain is unmeasurable here. Baseline gate green. Bench green (perf: ok — for-in/of are new
    statement paths, off the existing loop benches; loop_mix −13.2% / loop_sum −11.5% / str_build −12.6%
    vs base; ljs 0.2–0.5× Node).
  - **Landed:** for-in (own + inherited enumerable string keys, each once, Array indices, `length`
    skipped, built-in prototypes skipped, null/undefined → no-op); for-of (Array/String values,
    non-iterable → TypeError); `break`/`continue`; per-iteration `let`/`const` binding scope;
    declaration heads (single binding) + assignment-target heads (identifier / member / index); the
    `[~In]` for-header disambiguation (`for (a in b)` vs `for ((a in b);;)`). propertyHelper.js now
    parses (the runtime built-ins gap remains, deferred to a built-ins milestone).
    **Deferred (later cycles below):** the general `Symbol.iterator` iterator protocol;
    `Map`/`Set`/generator iterables; `for await` async iteration; labeled iteration statements;
    destructuring-pattern for-in/of heads beyond a single identifier/member/index; strict spec
    enumeration ordering for non-array own string keys; the sloppy annex-B `for (var x = init in y)`
    legacy head.

## Cycle 2 — Iterator protocol generalization (`Symbol.iterator`) (deferred)
- [ ] M5-T020 Once `Symbol` (well-known symbols) exists, generalize `for-of` (and array/call spread,
  array-pattern destructuring) to the §7.4 iterator protocol: `GetIterator` → `[Symbol.iterator]()`,
  `IteratorStep` → `.next()` returning `{ value, done }`, `IteratorClose` on early exit (break/throw).
  Replace the Array/String special-case in `iterableToSlice`/for-of with the protocol while keeping the
  Array/String fast paths. Unlocks user-defined iterables, `Map`/`Set`, generators.

## Cycle 3 — Labeled iteration + edge cases (deferred)
- [ ] M5-T030 §14.13 LabelledStatement + labeled `break label` / `continue label` targeting an
  enclosing loop; the remaining §14.7.5.1 Early Errors the new for-in/of heads expose (e.g. a for-of
  head whose LHS is `let`-named `let`; duplicate bound names); destructuring-pattern for-in/of heads
  (`for (const [a, b] of pairs)` / `for (const {k} in obj)`); the sloppy annex-B legacy
  `for (var x = init in obj)` head if tests demand it. Each gated by the regression hunt.

## Dependencies / order
Ordered by impact-to-effort and spec layering: for-in + for-of statements first (Cycle 1 — the
harness-parse unblock is the dominant conformance lever; both share the §14.7.5 head/body machinery so
they land together), then the §7.4 iterator-protocol generalization (gated on `Symbol`), then labeled
iteration + the residual edge cases. Each cycle bench-gated; each cycle runs the before/after
regression hunt by `mode+path`.
