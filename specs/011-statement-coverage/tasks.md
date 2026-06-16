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

## Cycle 2 — do-while + labeled statements + labeled break/continue 🎯 (DONE)

**Result (full `language/` tree, harness): passed 15,869 → 16,007 (+138), 46.2% → 46.6%. Regression
hunt by `mode+path`: 163 recoveries / 25 regressions (6.5:1); all 25 are pre-existing FEATURE cuts the
newly-parseable labelled-statement syntax merely UNMASKED — not breakages: `await`-as-label inside
`async function`/`async generator` ×12 (async unimplemented — no `[Await]` context to reject the label),
`using`/`await using` `…label-statement` ×8 (explicit-resource-management unimplemented),
`labeled/decl-async-function`+`decl-async-generator` ×4 (async), `with/labelled-fn-stmt` ×1 (`with`
unimplemented). Continuity `language/expressions`: 8,030 → 8,024 (−6, all the 8 unmasked
`async-function`/`async-generator` `await`-as-label negatives, minus 2 recoveries); conformance% steady
at 47.3%. Bench: `perf: ok (no ljs-vs-self regression)`, ljs 0.2–0.5× Node (a label-less fast path —
`takeLabels()` returns an empty slice with no allocation when no label applies, so the hot loop is
unchanged; largest delta −8.7%, an improvement).**

- [x] M10-T060 **§14.7.2 do-while (`src/lexer.zig` + `src/parser.zig` + `src/ast.zig` +
  `src/interpreter.zig`)** — added `kw_do` to the lexer (+ to `isKeywordName` so `do` stays a valid
  IdentifierName property/member key — fixed 3 `reserved-words` true-regressions). `parseDoWhile`
  parses `do Statement while ( Expression ) ;` with the body via `parseSubStmt` (§14.5 restriction) and
  the trailing `;` ASI-optional (§14.7.2 special rule — consumed if present, never required). New AST
  `do_while_stmt`; interpreter runs the body, then tests the condition (body always runs ≥ 1×);
  `break`/`continue` handled like the other loops.
- [x] M10-T070 **§14.13 labeled statements (`src/parser.zig` + `src/ast.zig` + `src/interpreter.zig`)** —
  `parseLabeled` detects an `identifier :` prefix at statement start (disambiguated from
  ExpressionStatement / object literal), collects a chain (`a: b: stmt`), and wraps the LabelledItem in
  nested `labeled_stmt` AST nodes. §13.1.1 LabelIdentifier Early Errors: `yield` invalid in a generator
  body / strict; strict-reserved words invalid in strict; `await` invalid in a static block (`eval`/
  `arguments` ARE valid labels). §14.13.1 duplicate-label SyntaxError. Annex B B.3.2: a labelled
  `function` is legal only in a sloppy statement-list position — forbidden as an `if`/loop sub-statement
  body (new `parseSubStmt(loop_body)` + `parseLabeled(sub_position)`; this also tightened the pre-existing
  over-permissive `while`/`for function f(){}` cut — recovered `*/decl-fun.js`).
- [x] M10-T080 **§14.9/§14.8 labeled break/continue (`src/parser.zig` + `src/completion.zig` +
  `src/interpreter.zig`)** — `break`/`continue` take an optional LabelIdentifier (no-LineTerminator-before
  rule via `newline_before`; ASI otherwise). Optional label added to the `break_stmt`/`continue_stmt` AST
  nodes and the `.brk`/`.cont` Completion variants. Parse-phase Early Errors (§14.13.1): label must be in
  scope (`labels`); `continue label` must target an iteration label (`iteration_labels`); plain
  `break`/`continue` require an enclosing iteration/switch (`iteration_depth`/`switch_depth`); a function
  body resets the whole label/loop scope (`enterControlScope`/`exitControlScope`). Interpreter:
  `labeled_stmt` republishes its label(s) to `pending_labels` for the immediately-nested statement (loops/
  switch snapshot+clear them via `takeLabels`; a non-loop labelled statement absorbs a matching
  `break label`); loops match `loopHandles(comp_label, my_labels)` (label-less → innermost; labelled →
  matching label, else propagate). for-of closes the iterator on any abrupt loop exit (§7.4.11).
- [x] M10-T090 **Tests (`src/engine.zig`)** — `M10 do-while`, `M10 labeled break/continue` (incl. a
  label on a block vs the loop inside it, a label chain on one loop, labelled `break` out of a switch),
  and `M10 labeled statements: parse-phase Early Errors`. All green via `zig build test`.

## Next cycles (statement levers, ordered)
See spec.md "Next statement levers": break/continue/return placement Early Errors,
switch CaseBlock scoping + duplicate-default, `with` (§14.11) + strict Early Error (clears the remaining
`with/labelled-fn-stmt` unmask), var/let/const hoisting + redeclaration Early Errors + true TDZ,
then async/await (separate large milestone — clears the unmasked `async-*`/`await`-as-label negatives,
recovering the −6 `language/expressions` continuity dip), explicit-resource-management (`using`).
