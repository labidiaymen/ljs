# Feature Specification: test blocks

**Feature Branch**: `tjs-native` (milestone 008) | **Created**: 2026-06-27 |
**Status**: Draft

**Input**: Borrow Zig's first-class testing into Lumen. A `test "name" { ... }`
block lowers directly to a Zig `test` block; `lumen test <file.ts>` generates the
Zig and runs `zig test`, which discovers and runs the blocks. `expect(cond)`
lowers to `std.testing.expect`.

A generated file carries both `main` and `test` blocks — `lumen compile` builds
the executable (Zig ignores the tests) and `lumen test` runs the tests (Zig
ignores `main`).

## Requirements

- **FR-001**: `test "name" { ...statements... }` declares a named test at the top
  level. `test` remains usable as an identifier where not followed by a string.
- **FR-002**: `expect(cond)` asserts a boolean inside a test block; a non-boolean
  argument reports `E_TYPE_MISMATCH`, and `expect` outside a test is rejected.
- **FR-003**: `lumen test <file.ts>` compiles the file and runs its test blocks
  via `zig test`, exiting non-zero if any test fails.
- **FR-004**: Test blocks may call top-level functions and use the V1 statement
  surface (console.log, locals, control flow).

## Success Criteria

- **SC-001**: A file with passing `test` blocks exits 0 under `lumen test`.
- **SC-002**: `expect` with a non-boolean argument fails to compile.
- **SC-003**: `zig build conformance` passes (new `test-run` phase) with the
  feature 008 manifest.
