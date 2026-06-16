# 032 — Tasks

- [x] T1 — AST: add `using_decl` + `await_using_decl` to `ast.DeclKind`.
- [x] T2 — Builtins: add `dispose` / `asyncDispose` well-known symbols; add `SuppressedError`
  constructor (native), `.prototype.name`, proto chain to %Error.prototype%.
- [x] T3 — Parser: contextual `using` / `await using` declaration in statement position; Early
  Errors (initializer required, BindingIdentifier-only, `let` target rejected, Script-top-level
  prohibition, `await using` async-only). Track a `top_level` flag for the Script-goal rule.
- [x] T4 — Parser: `for`-head handling — `using`/`await using` allowed in for-of and C-style head,
  rejected for for-in. `for (using of …)` stays an identifier.
- [x] T5 — Interpreter: dispose stack on the interpreter; `using` declaration evaluation pushes a
  DisposableResource (GetDisposeMethod + callable check + null/undefined no-op).
- [x] T6 — Interpreter: DisposeResources epilogue on Block / FunctionBody / for-loop / for-of exit
  (normal + abrupt), LIFO, SuppressedError aggregation, gated on a non-empty stack so ordinary
  block exit is free. `await using` awaits each async dispose where the await substrate reaches.
- [x] T7 — `src/engine.zig` unit tests (body/dispose order, LIFO, throw-disposes, null no-op,
  non-callable TypeError, contextual identifier).
- [x] T8 — Gates: `zig build`, `zig build test`, `zig build lint` (0/0), full `language/`
  conformance (≥36555 passed, 0 regressions vs baseline), `zig build bench` (perf ok). Update baseline.
