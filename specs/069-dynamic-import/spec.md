# Feature Specification: dynamic `import()` ImportCall (§13.3.10)

**Feature Branch**: `069-dynamic-import` (milestone **M81**)
**Created**: 2026-06-18
**Status**: Done — language 89.6%->90.3% (39444, +336 vs M80, 0 regressions).
dynamic-import dir 717->1041 (+324); `syntax/invalid` 714/714 (100%); `syntax/valid` base
proposal recovered (the remaining `valid` failures are the out-of-scope import-source /
import-defer / import-attributes proposals + one pre-existing tagged-template gap).

**Input**: ECMA-262 §13.3.10 ImportCall. The dynamic `import(specifier)` expression is the
LANGUAGE part of modules (in scope per CLAUDE.md's 2026-06-17 scope expansion — the module
grammar + a minimal harness loader are permitted; general Node host APIs stay out). This cycle
implements PARSING + the early errors + a genuine Promise result. Full module LOADING is NOT
implemented: a parsed `import(x)` ToString-es the specifier and returns a Promise that REJECTS
with a TypeError ("module loading is not supported"). The point is correct PARSING, correct
early SyntaxErrors, and returning a real Promise object (so `.then`/`.catch` and `assert.throws`
on the synchronous result behave).

Grammar (§13.3.10):

```
ImportCall :
    import ( AssignmentExpression[+In, ?Yield, ?Await] ,opt )
    import ( AssignmentExpression[+In, ?Yield, ?Await] , AssignmentExpression[+In, ?Yield, ?Await] ,opt )
```

The second form carries the import-options / attributes object (a single optional 2nd argument).
ImportCall is a `CallExpression` (so `import('x')(...)`, `import('x').then`, `import('x')['then']`
all parse), but it is NOT a `NewExpression` target and is NOT a simple assignment target.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — valid `import()` parses (Priority: P1)
1. **Given** script code, **When** `import('./x.js')` appears in any nested position (arrow,
   async-arrow, function, block, if/else, while, do-while, with, labeled block), **Then** it
   parses without a SyntaxError.
2. **Given** `import('')` followed by call/member/index, **When** `import('x')()` /
   `import('x').then(...)` / `import('x')['then']`, **Then** it parses (ImportCall is a
   CallExpression).
3. **Given** the empty-string specifier `import('')` / a template-literal specifier
   `` import(`x`) ``, **Then** it parses.
4. **Given** the 2-argument form `import('x', {})` (import options), **Then** it parses; a
   trailing comma after the 1st (`import('x',)`) or 2nd (`import('x', {},)`) argument parses.

### User Story 2 — invalid forms are early SyntaxErrors (Priority: P1)
1. `import()` — no argument (AssignmentExpression is not optional) → parse SyntaxError.
2. `import('a', 'b', 'c')` — three arguments (ImportCall takes at most two) → parse SyntaxError.
3. `import(...['x'])` — a spread as the (sole) argument is a Forbidden Extension → parse
   SyntaxError.
4. `import('x', ...[])` — a spread anywhere in the argument list → parse SyntaxError.
5. `new import('x')` / `new import('x').prop` — ImportCall is not a NewExpression target → parse
   SyntaxError.
6. `import('')++` / `import('')--` / `++import('')` / `--import('')` — ImportCall is not a simple
   assignment target (UpdateExpression operand) → parse SyntaxError.
7. `import('') = 1` / `import('') += 1` (and every compound/logical assignment operator) →
   parse SyntaxError (invalid assignment target).
8. `typeof import` — a bare `import` not followed by `(` (or `.`) → parse SyntaxError.
9. `import.UNKNOWN(...)` — a meta-property other than `import.meta` → parse SyntaxError. (We do
   NOT implement `import.meta`; `import.<anything>` stays a SyntaxError, which is the correct
   outcome for `import.UNKNOWN`.)

### Regression guards
1. Static `import`/`export` declarations stay parse-rejected (still unimplemented) — a bare
   `import` not followed by `(` or `.` is a SyntaxError, exactly as before.
2. `import.source(...)` / `import.defer(...)` (source-phase / deferred-import PROPOSALS, out of
   scope) stay parse-rejected — their valid tests are NOT recovered (and require no change), and
   their `invalid` (negative-parse) tests PASS precisely because we reject the syntax.
3. Ordinary spread calls (`f(...x)`) and ordinary `new f(x)` are unaffected.

## Success Criteria

- The base-proposal `dynamic-import/syntax/valid/**` tests that do NOT use the import-source /
  import-defer / import-attributes proposal grammar parse and run (the `import(x)` evaluates to a
  Promise; the test asserts the runtime TypeError rejection or simply that parsing succeeded).
- All `dynamic-import/syntax/invalid/**` negative-parse tests pass (we emit a parse SyntaxError),
  INCLUDING the import-source/import-defer invalid variants (rejecting their syntax IS the
  expected SyntaxError).
- `import(x)` returns a real Promise (rejected with a TypeError) so the `usage`/`returns-promise`
  style synchronous checks that only need a Promise object behave; tests that need actual module
  loading remain failing (out of scope — no loader).
- No regression elsewhere (`zig build` / `test` / `lint` green; no bench regression).
- Measured delta over the `dynamic-import` tree reported at the gate.

## Out of Scope

- Module LOADING / linking / evaluation (no harness loader in this cycle).
- `import.meta` (left a SyntaxError — not implemented).
- `import.source(...)` / `import.defer(...)` source-phase / deferred proposals.
- Static `import`/`export` declarations.
