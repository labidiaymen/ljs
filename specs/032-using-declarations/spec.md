# 032 — `using` / `await using` declarations (Explicit Resource Management, §ER)

## Problem
The pinned Test262 ships `language/statements/using` (~152 cases) and `language/statements/await-using`
(~184 cases) plus a slice under `for-of` / `for-await-of` — Stage-4 Explicit Resource Management.
ljs had no `using`/`await using` support: every such declaration was a parse error (the `using`
identifier ran into `=` as an unexpected token), and there were no `Symbol.dispose`/`Symbol.asyncDispose`
well-known symbols nor a `SuppressedError` constructor.

## Spec clauses
- §14.3.1 `using [no LineTerminator here] BindingList` / `await [no LineTerminator here] using
  [no LineTerminator here] BindingList` — UsingDeclaration / block-scoped lexical declarations.
- §14.3.1.1 Early Errors:
  - each `LexicalBinding` MUST be `BindingIdentifier Initializer` — a BindingPattern target is a
    Syntax Error, and a missing `Initializer` is a Syntax Error.
  - the bound name may not be `let`.
  - **Script goal**: a UsingDeclaration not contained (directly/indirectly) within a Block,
    ForStatement, ForInOfStatement, FunctionBody, GeneratorBody, AsyncGeneratorBody,
    AsyncFunctionBody, ClassStaticBlockBody, or ClassBody is a Syntax Error. (Allowed at the top
    level of a *Module*; we only parse Script — module tests are skipped by the runner — so the
    rule reduces to "not at Program top level".)
- `using`/`await using` is a **contextual** keyword: `using` is the declaration head only when
  followed (no LineTerminator) by a `BindingIdentifier` that is NOT `of` (so `for (using of …)` is
  the for-of of an identifier `using`). Otherwise `using` is an ordinary IdentifierReference
  (`var using = 1; using;` → 1; `using\nx` is two statements).
- §14.7.5 for-heads: `using`/`await using` are NOT allowed as a `for-in` head (Syntax Error), ARE
  allowed in a `for-of` head and in a plain C-style `for (using x = … ; ; )`.
- §15.8.1: `await using` outside an async context is a Syntax Error.
- §ER AddDisposableResource / CreateDisposableResource / GetDisposeMethod — evaluating
  `using x = expr` binds `x` (block-scoped) then, if `expr` is not null/undefined, reads
  `expr[@@dispose]` (`await using`: `expr[@@asyncDispose]`, else `expr[@@dispose]`), which must be
  callable (else TypeError), and pushes a DisposableResource onto the block's dispose stack.
- §14.2.3 Block Evaluation + §ER DisposeResources — at block/function/for exit (normal OR abrupt),
  run each pushed dispose method in REVERSE (LIFO) order with `this` = the resource value. For
  `await using`, the dispose result is awaited. A disposer that throws when a prior error is already
  pending is aggregated into a `SuppressedError { error, suppressed }` chain (innermost-suppressed
  is the original completion).
- §20.4.2 well-known symbols `@@dispose` / `@@asyncDispose`; §20.5.x `SuppressedError`.

## Behaviour (observable)
```js
var log = [];
{ using x = { [Symbol.dispose](){ log.push('d'); } }; log.push('body'); }
log.join(',');                               // "body,d"

{ using a = { [Symbol.dispose](){ log.push('a'); } },
        b = { [Symbol.dispose](){ log.push('b'); } }; }   // disposes b then a (LIFO)

try { { using x = { [Symbol.dispose](){ disposed = true; } }; throw 1; } } catch {}  // x disposed

using y = null;                              // no-op (no dispose)
using x = { [Symbol.dispose]: 1 };           // TypeError (not callable)

var using = 5; using;                        // 5 — contextual identifier still works
```

## Design
1. **Lexer**: `using` stays an ordinary identifier (contextual, like `of`/`async`).
2. **AST**: extend `DeclKind` with `using_decl` and `await_using_decl`; `ForHead.decl.kind` reuses
   the same enum. A new `block_has_using` parse-time signal is not stored on the AST — instead the
   interpreter gates the dispose machinery on a per-frame dispose stack that is only non-empty when a
   `using` actually ran (so ordinary block exit pays nothing).
3. **Parser**: in statement position, detect `using <BindingIdentifier>` / `await using
   <BindingIdentifier>` (contextual, same-line, target ≠ `of`/`let`) and parse a declaration with
   the new kinds; enforce the §14.3.1.1 Early Errors (initializer required, identifier-only target,
   Script-top-level prohibition, `await using` async-only). In a `for`-head, route `using`/`await
   using` like `let`/`const` but reject the `for-in` form.
4. **Interpreter**: a dispose stack (`disposables`: list of `{ value, method, is_async }`) on the
   interpreter. `runScope`/`runBlock`/function-body/for-loop frames that contain a `using` push a
   stack marker (the start length), run the body, then `DisposeResources` from that marker in reverse
   with SuppressedError aggregation, threading the original completion. Gated: a frame with no
   `using` never grows the stack, so the dispose epilogue is a single length-compare (free).
5. **Builtins**: add `@@dispose` / `@@asyncDispose` well-known symbols and a `SuppressedError`
   constructor (with `.prototype.name = "SuppressedError"`, inherits %Error.prototype%).

## Out of scope / deferred
- Full `await using` async-dispose await sequencing inside async generators beyond what the existing
  await substrate supports is implemented where the await machinery reaches; any residual async-only
  cases that still fail are noted in the delta, not forced.

## Delta (result)
- **Landed (both sync `using` AND `await using`):** parse (contextual `using` / `await using`, all
  §14.3.1.1 Early Errors — initializer-required, BindingIdentifier-only, `let`-target, Script-top-
  level prohibition, switch-case-clause prohibition, `for-in` prohibition, `await using` async-only,
  the `for (using x of []) { var x; }` VarDeclaredNames clash); runtime DisposeResources on Block /
  try-catch-finally / FunctionBody / GeneratorBody / AsyncFunctionBody / AsyncGeneratorBody / C-style
  for-loop / per-iteration for-of exit, LIFO, SuppressedError aggregation, `await using` awaits each
  async dispose (incl. the null-resource microtask boundary). `@@dispose` / `@@asyncDispose` well-
  known symbols + `SuppressedError` constructor.
- **Conformance:** `statements/using` 26→142/152 (94.7%), `statements/await-using` 28→174/184
  (95.6%); full `language/` 36555→36819 (83.7%→84.3%), 0 regressions.
- **Still failing (all PRE-EXISTING engine limitations, NOT `using`-specific):** block/declaration
  empty-completion value (`4; {let/using x=…}` → should yield 4); duplicate-lexical-declaration Early
  Error (`{using f; var f}`); TDZ enforcement (`for (using x of [x])`); `let` as an identifier/binding
  name (the `using let`-split tests); a comma-sequence inside an index (`a[0,1,2]`, used by the
  `for (using of of […])` tests); and the `deepEqual.js` harness file failing to lex (`#${}` in a
  template). Each affects the `let`/`const`/general path identically and is out of M32 scope.
