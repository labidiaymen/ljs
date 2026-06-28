# Implementation Plan: `using` Declarations & Disposables

## Approach

`using` reuses the existing `defer`-statement lowering. The `defer` statement
already emits a native `defer { ... }` block inline at its site, which provides
LIFO scope-exit ordering and correct interleaving among all scope-exit cleanups.
A `using` declaration therefore lowers to: (optionally) a value binding, followed
by a `defer { <dispose> }` block emitted inline at the declaration site.

Two disposal shapes are recognized:

1. **`using x = defer(() => BODY)`** — the built-in helper. The arrow body is
   captured at parse time as a statement list (so `console.log(...)` works, since
   it has no expression form) and run verbatim inside the emitted `defer` block.
   No value binding is made — the bound name is an opaque `Disposable`.
2. **`using r = EXPR`** where `EXPR` is a class instance with `dispose(): void` —
   `r` is bound, and a synthesized `r.dispose()` call runs inside the `defer`
   block.

## Pieces

1. **AST** (`src/lumen_ast.zig`)
   - `UsingDecl { name, emit_name?, annotation?, checked_type?, init,
     defer_body?: []Stmt, dispose_call?: *Expr, line, col }`.
   - `Stmt.using_decl` variant.

2. **Parser** (`src/lumen_compiler.zig`)
   - Parse `using NAME [: T] = EXPR;`.
   - Special-case `using NAME = defer(() => BODY);`: parse `BODY` as a block or a
     single body statement (`parseDeferHelperBodyStmt`, which recognizes
     `console.log`/`console.error`), store it as `defer_body`.
   - Helpers: `peekIsOpenParen`, `parseDeferHelperBodyStmt`.

3. **Checker** (`src/lumen_check.zig`)
   - `defer_body` form: type-check the body like a `defer` block (`checkBlock`).
   - dispose form: require `final_type == .class_type` with a zero-arg
     `dispose()` method (`resolveMethod`), else `E_NOT_DISPOSABLE`; bind the name;
     synthesize and check a `name.dispose()` call into `dispose_call`.

4. **Emitter** (`src/lumen_compiler.zig`, `emitStmtWithThrow`)
   - `defer_body` form: emit `defer { <body> }`.
   - dispose form: emit `const NAME = <init>;` then `defer { _ = NAME.dispose(); }`.
   - Cover `using_decl` in the diag line/col switch, `stmtUsesName`,
     `stmtCanThrow`, `stmtUsesThis`.

5. **Ambient `lumen.d.ts`** (repo root)
   - `interface Disposable { dispose(): void }` (merges with ESNext lib).
   - `declare function defer(fn: () => void): Disposable;`.

6. **Conformance** — `specs/027-using-disposables` examples + manifest;
   `build.zig` wiring (`conformance_cmd_027`).

## Notes / follow-ups

- `tsc` native `using` wants `[Symbol.dispose]()`, not `dispose()`. The
  `defer(...)` helper is the `tsc`-clean path; full `[Symbol.dispose]` class
  disposal (computed method names) is deferred.
- `cloneStmt` passes `using_decl` through unchanged (generic-body `using` is an
  edge case not exercised this cycle).
