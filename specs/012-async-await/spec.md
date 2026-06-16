# Feature Specification: M11 — Async / Await

**Feature Branch**: `012-async-await`

**Created**: 2026-06-16

**Status**: Cycle 1 (parsing + early errors) — runtime (Promise + Job queue) deferred to Cycle 2

**Input**: "M11: async/await. Async syntax (`async function`, `async (…) =>`, `async m(){}`, the
`await` operator) was entirely unparsed and kept causing unmasked regressions as other milestones
un-rejected surrounding syntax. The Test262 runner SKIPS `[async]`-flagged executable tests (they need
`$DONE` + the event loop — Cycle 2), but the large body of async SYNTAX and NEGATIVE/early-error tests
are NOT flagged `[async]`, so the runner already executes them and they currently fail to PARSE.
Implementing async parsing + the §15.8/§15.9 early errors recovers those without needing Promise or the
runtime. Async functions may throw a runtime stub for now."

## Why (data-driven)

At M10 close the full `language/` tree is **passed 16,007 / 46.6%** (harness metric);
`language/expressions` is **8,024 / 47.3%**. `async`/`await` was an unhandled construct: `async
function`, async arrows, async methods, and the `await` operator all parse-rejected, so the entire
`language/expressions/await/`, `language/expressions/async-function/`,
`language/expressions/async-generator/`, `language/expressions/async-arrow-function/`, and
`language/statements/async-function/` subtrees failed at parse — and, because async syntax wasn't
recognized, several `await`-as-identifier negatives and `async`-shaped templates elsewhere were masked
by a wholesale parse-reject. This cycle implements the SYNTAX + §15.8 early errors only; the runtime
(returning a Promise, the await microtask suspension) is Cycle 2.

## Approach: `async` / `await` as contextual keywords, mirroring `function*` / `yield`

`async` and `await` are NOT lexer keywords — they lex as ordinary `.identifier` tokens, and the parser
treats them contextually (exactly like `yield`/`of`/`static`):

- **`async` is a modifier** only when followed (with NO LineTerminator between — §15.8 restricted
  production) by `function` (→ async function), or by an arrow head (`async x =>`, `async (params) =>`).
  Otherwise `async` is an ordinary IdentifierReference (`async`, `async()` call, `async + 1`, `async\nx`).
- **`await` is the operator** (`await UnaryExpression`, §15.8) ONLY inside an async function / async
  arrow / async method body — tracked by a new parser `in_async` context flag (mirroring `in_generator`).
  Outside async, `await` is an ordinary identifier (sloppy).
- An async generator (`async function* g(){}`, `async *m(){}`) sets BOTH `in_async` and `in_generator`
  for its body, so both `await` and `yield` are live operators there.

A new `Function.is_async` AST flag (alongside `is_generator`) and an `await_expr` node carry async into
the interpreter, where — for this cycle — calling an async function or evaluating an `await` raises a
"not yet supported at runtime (Cycle 2)" error. Parse / early-error tests are `$DONOTEVALUATE` or
negative-parse so they never reach runtime; the executable async tests are `[async]`-skipped by the
runner. The ordinary (non-async) call path is untouched (a single optional-field test before dispatch),
keeping the bench gate green.

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Re-measure the full `language/` tree (PRIMARY) + `language/expressions`
(continuity) and run the mandatory before/after `mode+path` regression hunt (un-rejecting async syntax
turns parse-negatives into runtime, but async executables are skipped and the §15.8 early errors keep
the genuine negatives red).

### US1 — async function declaration + expression (§15.8) (P1)
`async function f(){}` parses as a declaration (hoisted) + as an expression; `typeof (async
function(){})` is `"function"`. `async function* g(){}` (async generator) parses. **Test**: covered.

### US2 — async arrow functions (§15.8) (P1)
`async x => …`, `async (a, b) => …`, `async () => …` parse via the arrow cover-grammar (an `async`
modifier before an arrow head), distinguished from a call `async(x)` by the trailing `=>`. **Test**:
covered.

### US3 — async methods in class / object bodies (§15.8 / §15.6) (P1)
`{ async m(){} }`, `{ async *m(){} }`, `class C { async m(){} }`, `static async m(){}`, computed
`async ['x'](){}` parse. **Test**: covered.

### US4 — the `await` operator (§15.8) (P1)
`await UnaryExpression` is the operator inside an async body (`return await x`, `await f()`). Outside
async (sloppy), `await` is an identifier (`function f(){ var await = 1; return await }` → 1). **Test**:
covered.

### US5 — §15.8.1 early errors (P1)
`await` as a BindingIdentifier inside an async context (`async function f(){ var await }`, an async
param `await`, an async arrow param `await`, an async function named `await`) is a SyntaxError; `await`
reaching IdentifierReference position inside an async body is a SyntaxError; `(await x)++` /
`++(await x)` are SyntaxErrors; async (and async-generator) functions have UniqueFormalParameters.
**Test**: covered.

### Edge Cases
- §15.8 restricted production: a LineTerminator after `async` un-sets the modifier (`async\nfunction
  f(){}` is the expression statement `async` then a `function` declaration; `async\nx => …` is `async`
  then a separate arrow). Honored via the tokens' `newline_before` flag.
- An ordinary (non-async) arrow / function body parses `~Await` — `await` does NOT cross into a nested
  non-async function. But an arrow inside an async function inherits `[+Await]` for its body (await is
  the operator there), like the `[?Await]` grammar parameter.
- A non-async arrow inside a generator still inherits `[+Yield]` (unchanged from M9).

## Requirements *(mandatory)*
- **FR-001** (US1–US5): `ast.Function.is_async` flag; an `await_expr` node (`*const Node` operand).
- **FR-002** (US1–US4): parser `in_async` context flag (saved/restored around every function body, set
  for async functions/arrows/methods, false across the FormalParameters which parse `~Await`); parse
  `async function` decl/expr, async arrows (cover grammar), async methods (class + object, with optional
  `*` for async generators); the `await` operator at UnaryExpression precedence inside an async body.
- **FR-003** (US5): §15.8.1 early errors — `await` as a BindingIdentifier (name/param/body var) in an
  async context, `await` IdentifierReference inside async, async UniqueFormalParameters, `(await x)++`.
- **FR-004** (runtime stub): `object.FunctionData.is_async`; calling an async function and evaluating an
  `await` raise a deferred-runtime error. The real Promise + microtask/Job runtime is Cycle 2.

## Out of scope (this cycle)
- Promise, the microtask / Job queue, the async-function [[Call]] returning a Promise, the `await`
  suspension/resume. (Cycle 2.)
- Top-level await (a module feature; ljs has no module loader — out of ECMAScript-only scope here).
- The Test262 runner's `[async]` / `$DONE` support (Cycle 2).
