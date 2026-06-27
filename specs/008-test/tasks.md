# Tasks: test blocks

- [x] T1 Add `test_decl` to the AST; parse `test "name" { ... }` (string-gated).
- [x] T2 Type-check test bodies; add `expect(bool)` (test-only).
- [x] T3 Emit Zig `test "name" { ... }` blocks into top-level decls; `expect`
  lowers to `try std.testing.expect(...)`.
- [x] T4 Add `lumen test <file.ts>` running `zig test`.
- [x] T5 Add a `test-run` conformance phase; valid + invalid example + manifest.
