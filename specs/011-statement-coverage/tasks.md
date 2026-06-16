---
description: "Task list for M10 — statement coverage (§14.4 / §14.5 / §15.7 / §14.3, conformance-driven)"
---

# Tasks: M10 — Statement Coverage

**Metric:** conformance reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`), same as M4–M9. The PRIMARY gate is now the FULL `language/` tree
(`baseline/language-expressions.json` remains the `language/expressions` continuity floor). The
`language/statements/*` half lagged `language/expressions/*`; M10 closes that gap statement by statement.

**Cadence**: one cycle = one coherent slice of statement coverage = one commit (build + test + lint +
**bench (ljs ≤ Node)** green). Re-measure the FULL `language/` tree each cycle (primary) + the
`language/expressions` continuity number.

**Mandatory regression hunt (every cycle):** un-rejecting newly-parseable statement syntax converts
parse-negatives into reachable-runtime tests. `git stash` + rebuild ReleaseFast + measure BEFORE vs
AFTER on the FULL `language/` tree, `awk '{print $2,$3}' | sort` + `comm`; true regressions 0 or far
outweighed by recoveries. Where a recovery would net a regression (a parse-negative now parses-OK but
ljs lacks the precise Early Error), either add that Early Error OR note it as a documented pre-existing
cut to be cleared in a later cycle.

## Cycle 1 — EmptyStatement + class-decl block scope + §14.5 substatement restriction 🎯 (DONE)

**Result (full `language/` tree, harness): passed 14,039 → 15,869 (+1,830), 40.9% → 46.2%. Regression
hunt by `mode+path`: 1,901 recoveries / 71 regressions (27:1; all 71 are pre-existing feature cuts
EmptyStatement merely UNMASKED — not breakages: `block-scope/syntax/redeclaration` ×36 (duplicate
var/lexical Early Error, M1 cut), `async-*` ×16 + `if-stmt-else-async-*` ×4 + `for-of/head-lhs-async`
×2 (async unimplemented), `with` ×4 (with unimplemented/strict Early Error), `return` ×4 + `continue`
×2 (placement Early Errors), `do-while` ×3 (do-while unimplemented). Continuity `language/expressions`:
7,922 → 8,030 (+108), 46.7% → 47.3% (no regression — EmptyStatement also helps expressions). Bench:
`perf: ok (no ljs-vs-self regression)`, ljs 0.3–0.6× Node (parse-time-only changes, no hot path).**

**Orchestrator entry hypothesis was STALE:** "class declarations unwired into `parseStmt`, 4,758
failing" — class declarations in statement position (parse `kw_class` → `parseClass(true)`, AST
`class_decl`, interpreter `evalClass` + name binding) were fully wired and passing since M4. The real
4,758 `statements/class/*` failures were dominated by the missing §14.4 EmptyStatement production
(`class C {};` trailing `;`), not by class declarations.

- [x] M10-T010 **§14.4 EmptyStatement (`src/parser.zig`)** — handle a leading `.semicolon` in
  `parseStmtInner`: consume the `;` and return a no-op modeled as an empty `Block` (`.block = &.{}`),
  reusing the interpreter's existing empty-block no-op (no new AST variant; `blockNeedsScope(&.{})` is
  false → no scope alloc). Fixes bare `;`, `;;`, `var x=1;;`, trailing `;` after class/function
  declarations (`class C {};`), and empty `if`/loop bodies.
- [x] M10-T020 **Class-declaration block scoping (`src/interpreter.zig`)** — add `.class_decl` to
  `blockNeedsScope` (§15.7 / §14.3: a ClassDeclaration is a block-scoped lexical binding like `let`).
  Fixes the leak where a block whose only declaration was a class reused the parent env
  (`{ class Q {} } new Q()` resolved). Statement-form class parse/bind/eval were already done (M4).
- [x] M10-T030 **§14.5 substatement restriction (`src/parser.zig`)** — new `parseSubStmt` (used by
  `if`/`else`/`while`/`for`/`for-in`/`for-of` bodies): reject a `Declaration` in single-statement-body
  position — `let`/`const`, `ClassDeclaration`, `function*` (always); plain `function` (strict only;
  sloppy Annex B B.3.4 keeps it legal). The `let` case honors the ExpressionStatement
  `[lookahead ∉ { let [ }]` rule via the `newline_before` token flag: `let [` → reject; same-line
  `let` + BindingIdentifier/`{` → reject; `let` + LineTerminator + identifier → ASI → allow (identifier
  expression). Cleared the `if/while/for-*` decl-body negatives (`if-cls`/`if-let`/`if-const`/`if-gen`,
  `for*/decl-*`, `let-array-with-newline`) while keeping `let-identifier-with-newline` positives green.
- [x] M10-T040 **Sanity check: function & generator DECLARATIONS in statement position** — confirmed
  `function f(){}` and `function* g(){}` already parse + bind as statements (`g().next().value` works).
  No fix needed.
- [x] M10-T050 **Tests (`src/engine.zig`)** — `M10 EmptyStatement (§14.4)` (bare/doubled `;`, trailing
  `;` after class/function decls, empty if/loop bodies) + `M10 classes: declaration in statement
  position is block-scoped (§15.7 / §14.3)` (statement-form method call, derived `instanceof`, block
  scoping, use-before-declaration ReferenceError, anonymous-`class {}` SyntaxError, class-as-expression
  still works, `function*` decl). All green via `zig build test`.

## Next cycles (statement levers, ordered)
See spec.md "Next statement levers": do-while, labeled statements + labeled break/continue,
break/continue/return placement Early Errors, switch CaseBlock scoping + duplicate-default,
`with` (§14.11) + strict Early Error, var/let/const hoisting + redeclaration Early Errors + true TDZ,
then async/await (separate large milestone — gates many unmasked `async-*` negatives).
