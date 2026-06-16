# Feature Specification: M10 — Statement Coverage

**Feature Branch**: `011-statement-coverage`

**Created**: 2026-06-16

**Status**: Cycle 1 done (EmptyStatement + class-decl block-scope + §14.5 substatement restriction; full
`language/` conformance 40.9% → 46.2%)

**Input**: "M10: statement coverage. The conformance corpus now covers the full `language/` tree. The
biggest remaining lever is the `language/statements/*` subtree, which lagged `language/expressions/*`.
Cycle 1 entry hypothesis (from the orchestrator): `class C {…}` in STATEMENT position throws
SyntaxError — class declarations were never wired into `parseStmt`; `language/statements/class/*` =
4,758 failing. Attack that lever."

## Why (data-driven)

At M9 close the full `language/` tree is **passed 14,039 / 40.9%** (harness metric). The
`language/statements/*` half lags `language/expressions/*` (46.7%). The orchestrator's stated entry
hypothesis — *class declarations are unwired* — turned out to be **stale**: class declarations in
statement position were fully wired in M4 (parser `kw_class` → `parseClass(true)`, AST `class_decl`,
interpreter `evalClass` + name binding) and pass. Investigation of the real 4,758 `statements/class/*`
failures (3,595 parse_error + 1,149 unexpected_error) revealed the true root cause:

- **The parser had no §14.4 EmptyStatement production.** A bare `;` anywhere as a statement was a
  SyntaxError. This broke every Test262 template that emits a trailing `;` after a declaration — the
  ubiquitous `class C {};` / `function f(){};` form — plus `;;`, `var x=1;;`, empty `if`/loop bodies
  (`if (x) ; else ;`, `for (…) ;`, `while (…) ;`). This single gap cascaded across the whole
  `statements/*` (and parts of `expressions/*`) tree. **The dominant lever was EmptyStatement, not
  class declarations.**

## Approach

Three small, spec-cited parser/interpreter fixes, each conformance-measured with the mandatory
before/after `mode+path` regression hunt on the FULL `language/` tree:

1. **§14.4 EmptyStatement** (`src/parser.zig`): a leading `.semicolon` in `parseStmtInner` consumes the
   `;` and returns a no-op, modeled as an empty `Block` (zero statements) — the interpreter already runs
   an empty block as a no-op without allocating a scope (`blockNeedsScope` is false for an empty slice),
   so no new AST variant / interpreter / lint surface.
2. **§15.7 / §14.3 class-declaration block scoping** (`src/interpreter.zig`): `blockNeedsScope` did not
   list `.class_decl`, so a block whose only declaration was a class reused the parent env and leaked
   the class name to the enclosing scope (`{ class Q {} } new Q()` resolved — a bug). A ClassDeclaration
   is a block-scoped lexical binding (like `let`); add `.class_decl` to `blockNeedsScope`.
3. **§14.5 substatement restriction** (`src/parser.zig`): the single-statement body of
   `if`/`else`/`while`/`for`/`for-in`/`for-of` is a `Statement`, not a `Declaration`. A new
   `parseSubStmt` rejects a leading lexical declaration (`let`/`const`), `ClassDeclaration`, or
   `GeneratorDeclaration` (`function*`) in body position; a plain `FunctionDeclaration` is rejected only
   in strict mode (sloppy Annex B B.3.4 keeps it legal as an `if`/`else` body — those positives live
   under `annexB/`, outside the measured `language/` tree). The `let` case honors the ExpressionStatement
   `[lookahead ∉ { let [ }]` rule: `let [` is always a declaration (reject); `let` + same-line
   BindingIdentifier/`{` is a declaration (reject); `let` followed by a LineTerminator then an identifier
   is ASI → `let` is an IdentifierReference ExpressionStatement (allow).

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Each cycle adds a coherent slice of statement coverage, re-measures the FULL
`language/` tree (the primary gate now) plus `language/expressions` (continuity), runs the mandatory
before/after regression hunt by `mode+path` (un-rejecting newly-parseable statement syntax converts
parse-negatives into reachable-runtime tests — a net gain is expected, true regressions must be 0 or
far outweighed), and stays bench-green (ljs ≤ Node; these are parse-time-only changes — no hot path).

### US1 — §14.4 EmptyStatement (P1) — DONE
A bare `;` is a no-op Statement (not a SyntaxError); `;;`, a trailing `;` after a class/function
declaration (`class C {};`), and empty `if`/loop bodies all parse.
**Test**: `; 1` → 1; `;; 2` → 2; `class C { m(){return 9} }; new C().m()` → 9;
`function f(){return 5}; f()` → 5; `for (var i=0;i<3;i++); i` → 3; `if (true) ; else ; 7` → 7.

### US2 — Class declaration block scoping (§15.7 / §14.3) (P1) — DONE
A ClassDeclaration creates a block-scoped lexical binding (like `let`), not a leaking function-style
binding. (Statement-form class parse + bind + eval were already wired in M4.)
**Test**: `class C { m(){return 7} } new C().m()` → 7; `class A{} class B extends A{} new B() instanceof A`
→ true; `{ class Q {} } typeof Q` → `"undefined"`; `{ class Q {} } new Q()` → ReferenceError;
`new D(); class D {}` → ReferenceError (use-before-declaration; observably TDZ-like — see note);
anonymous `class {}` in statement position → SyntaxError.

### US3 — §14.5 substatement restriction (P1) — DONE
A `Declaration` is not a valid single-statement body of `if`/`else`/`while`/`for`/`for-in`/`for-of`.
**Test**: `if (true) class C {}` → SyntaxError; `if (true) let x;` → SyntaxError; `while (0) const x=1;`
→ SyntaxError; `if (true) function* g(){}` → SyntaxError; `"use strict"; if (1) function f(){}` →
SyntaxError; sloppy `if (1) function f(){}` → OK (Annex B); `while (0) let\nx=1` → OK (ASI: `let` is an
identifier); `while (0) let\n[a]=0` → SyntaxError (`let [`).

### Edge Cases / Notes
- An EmptyStatement is modeled as an empty `Block` (`.block = &.{}`) — no new AST variant; the
  interpreter runs zero statements as a no-op and `blockNeedsScope(&.{})` is false (no scope alloc).
- Use-before-declaration of a class in the same scope is observably a ReferenceError. This engine has no
  separate hoisting pass (documented M1 cut: `var`/lexical declarations bind on reaching them, not
  hoisted), so the ReferenceError arises from "binding does not yet exist", which coincides with §14.3
  TDZ for the use-before-declaration case. A full TDZ (declared-but-uninitialized window) is not modeled.
- `function f(){}` and `function* g(){}` DECLARATIONS in statement position already parse + bind (M-prior);
  sanity-checked in Cycle 1, no fix needed.

## Requirements *(mandatory)*
- **FR-001** (US1): Parse §14.4 EmptyStatement (`;`) as a no-op Statement in every statement position.
- **FR-002** (US2): A ClassDeclaration is a block-scoped lexical binding; a block containing one needs
  its own declarative scope (no leak to the enclosing scope).
- **FR-003** (US3): Reject a `Declaration` (`let`/`const`/class/`function*`, and `function` in strict)
  as the single-statement body of `if`/`else`/`while`/`for`/`for-in`/`for-of` (§14.5), honoring the
  ExpressionStatement `let [` lookahead so a sloppy `let`-as-identifier body stays legal.

## Next statement levers (future cycles)
Ordered by the residual `language/statements/*` failure share + the unmasked regressions this cycle
surfaced (all pre-existing feature cuts, not breakages):
- **do-while** — `do … while (…)` is entirely unimplemented (`do` is not even a keyword). ~a full
  IterationStatement form + its early-error negatives (`do-while/S12.6.1_A12`, `let-array-with-newline`).
- **Labeled statements** (`Label: stmt`) + `break`/`continue Label` — break/continue currently carry no
  label; labeled-statement parsing + labeled break/continue targeting.
- **`break`/`continue`/`return` placement early errors** — `continue` outside an iteration, `return`
  outside a function (`statements/return/S12.9_*`, `continue/S12.7_A8_T2`) are §13/§14 Early Errors.
- **`switch`** edge cases (lexical scope of the CaseBlock; duplicate-`default` early error).
- **`with`** statement (§14.11) + its strict-mode Early Error (a `with` in strict is a SyntaxError;
  `statements/with/strict-fn-*`). Note: `with` is sloppy-only.
- **var/let/const hoisting + redeclaration Early Errors** (§14.3.1 / §8.2.x) — duplicate lexical
  declarations and var-vs-lexical conflicts (`block-scope/syntax/redeclaration/*`, 36 tests) are not yet
  SyntaxErrors (documented M1 cut). A proper top-of-scope hoisting/declaration pass would also give true
  `let`/`const` TDZ and `var` function-scoping.
- **try/catch** optional-binding + completion edge cases; **for-of/for-in** head edge cases
  (`head-lhs-async-invalid` once async lands).
- **async/await** (`async function` / `await`) — a separate large milestone; many unmasked negatives
  (`expressions/async-*`, `if-stmt-else-async-*`) depend on it.
