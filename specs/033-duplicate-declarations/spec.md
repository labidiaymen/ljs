# M33 — Duplicate-declaration Early Errors (§14.2.1 / §14.12.1 / §14.15.1 / §16.1.1)

## Goal
Enforce the ECMA-262 static-semantics Early Errors that reject duplicate declarations at
**parse time** (a `SyntaxError`, `negative: { phase: parse }`). This retires the staged M1 cut
documented in `src/interpreter.zig` ("duplicate lexical declarations are not yet a SyntaxError").

## Rules implemented
For each lexical scope — Block (§14.2.1), Script / FunctionBody (§16.1.1 / §15.2.1),
SwitchStatement CaseBlock (§14.12.1), and the Catch of a TryStatement (§14.15.1):

1. **LexicallyDeclaredNames must be unique.** `let` / `const` / `class` / `using` / `await using`
   (and, at *block* level, `function`) bound in the same lexical scope cannot repeat a name.
   - `{ let x; let x; }`, `{ const x=1; class x{} }`, `switch(0){case 1: let x; case 2: let x;}` → SyntaxError.

2. **LexicallyDeclaredNames ∩ VarDeclaredNames = ∅.** A lexical name cannot collide with a
   `var` / hoisted-function name reaching the same scope.
   - `{ let x; var x; }`, `{ function f(){} var f; }`, `{ {var f;} let f; }` → SyntaxError.
   - `VarDeclaredNames` of a block bubble UP from nested non-function descendant statements
     (inner blocks, `if`/`for`/`while`/`try` bodies, …) but STOP at a function boundary.

3. **Switch CaseBlock** merges the LexicallyDeclaredNames + VarDeclaredNames across ALL case /
   default clauses into a single scope (a `let` in `case 1` and another in `case 2` collide).

4. **Catch** — the CatchParameter's BoundNames cannot be re-declared as a LexicallyDeclaredName
   of the Catch Block. `try{}catch(e){ let e; }`, `try{}catch(e){ function e(){} }` → SyntaxError.

## Boundary (MUST NOT reject — Annex B / scoping)
- `var x; var x;` — `var` redeclaration is always legal.
- `function f(){} function f(){}` at **Script/FunctionBody top level** — legal (the duplicate is
  VarDeclared, not Lexical, at function/script scope). Inside a **block**, two function decls are a
  SyntaxError **only in strict mode** (Annex B B.3.3 relaxes it in sloppy block scope).
- `{ let x; } { let x; }` — different blocks; `let x; { let x; }` — nested shadow.
- `catch(e){ var x; }` with a simple-identifier param of a *different* name — fine; the Annex B
  catch-param-vs-`var` relaxation is preserved (we enforce only the lexical conflict for catch).
- A `var` in the function/script var-scope that merely *shares* a name with a `let` in a deeper
  block where they do not actually share a scope — no conflict.

## Approach
A post-parse static AST walk (`checkLexicalScope` in `parser.zig`) over each lexical scope,
collecting LexicallyDeclaredNames + the (bubbled) VarDeclaredNames, then checking rules 1–3.
Strictness threads in for the block-level function-vs-function and function-vs-lexical cases.
PARSE-TIME only — no runtime / hot-path impact, bench unaffected.

## Tests (src/engine.zig)
Negatives: `{ let x; let x; }`, `{ let x; var x; }`, `{ const x=1; class x{} }`,
`switch(0){case 1: let x; case 2: let x;}`, `try{}catch(e){ let e; }`, `{ {var f;} let f; }`.
Positives: `{ var x; var x; }`, `{ let x; } { let x; }`, `let x; { let x; }`,
`function f(){} function f(){}` (top level), `switch(0){case 1: let x; case 2: var x;}` stays
parseable where legal.

## Gates
`zig build` / `test` / `lint`; full `language/` ≥ 36819 with **no regression** vs
`baseline/language.json`; `zig build bench` "perf: ok".
