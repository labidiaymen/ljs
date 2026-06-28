# Tasks: `using` Declarations & Disposables

- [x] T1 — AST: `UsingDecl` struct + `Stmt.using_decl` variant.
- [x] T2 — Parser: `using NAME [: T] = EXPR;`; special-case
      `defer(() => BODY)` (`peekIsOpenParen`, `parseDeferHelperBodyStmt`).
- [x] T3 — Checker: `defer_body` form via `checkBlock`; dispose form requires a
      class instance with zero-arg `dispose()` (`E_NOT_DISPOSABLE`), binds the
      name, synthesizes a checked `name.dispose()` call.
- [x] T4 — Emitter: `defer { body }` for the helper; `const NAME = init;` +
      `defer { _ = NAME.dispose(); }` for the dispose form.
- [x] T5 — Emitter/traversal: `using_decl` arms in the diag line/col switch,
      `stmtUsesName`, `stmtCanThrow`, `stmtUsesThis`.
- [x] T6 — Ambient `lumen.d.ts`: `interface Disposable { dispose(): void }` and
      `declare function defer(fn: () => void): Disposable;`.
- [x] T7 — Examples: valid `using-defer.ts`, `using-dispose.ts`; invalid
      `using-non-disposable.ts`.
- [x] T8 — Conformance manifest + `build.zig` wiring (`conformance_cmd_027`).
- [x] T9 — Verify: `zig build` clean; LIFO + legacy-`defer` interleave + block
      scope verified by running examples; legacy `defer` statement still passes
      (007-defer green); `defer(...)` helper type-checks under `tsc` 5.5.
- [ ] T10 (follow-up) — `[Symbol.dispose]()` class disposal for full tsc-clean
      `using r = make()` (computed method names).
