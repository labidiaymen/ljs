# Tasks: Iteration, Enums, Interfaces, And Operators

**Input**: `spec.md`, `plan.md`

Four cycles. Each is independently shippable and ends with `zig build` +
`zig build conformance`.

## Cycle 1: for...of (P1)

- [x] C1.1 Add `for_of` statement node to `src/lumen_ast.zig`.
- [x] C1.2 Parse `for (const|let name of iterable) { ... }` in
  `src/lumen_compiler.zig`, branching from the C-style `for` path on `of`.
- [x] C1.3 Check iterable is array/string and bind the loop var to the element
  type in a loop scope in `src/lumen_check.zig`.
- [x] C1.4 Lower to index `while` with `break`/`continue` preserved in
  `src/lumen_compiler.zig`.
- [x] C1.5 Valid array+string example + invalid non-iterable example + manifest.
- [x] C1.6 `zig build` and `zig build conformance` pass.

## Cycle 2: enum (P2)

- [x] C2.1 Add `enum_type` to `src/lumen_types.zig` and `enum_decl` to
  `src/lumen_ast.zig`.
- [x] C2.2 Parse `enum Name { ... }` with numeric/string members in
  `src/lumen_compiler.zig`.
- [x] C2.3 Resolve `Enum.Member`, enum equality, and reject raw assignment in
  `src/lumen_check.zig`.
- [x] C2.4 Emit member backing values in `src/lumen_compiler.zig`.
- [x] C2.5 Valid enum example + invalid raw-assignment example + manifest.
- [x] C2.6 `zig build` and `zig build conformance` pass.

## Cycle 3: interface (P3)

- [x] C3.1 Parse `interface Name { ... }` into the existing `TypeDecl` path in
  `src/lumen_compiler.zig`.
- [x] C3.2 Valid interface example (param/return flow) + manifest.
- [x] C3.3 `zig build` and `zig build conformance` pass.

## Cycle 4: bitwise + exponent (P4)

- [x] C4.1 Lex `&`, `|`, `^`, `~`, `<<`, `>>`, `**` in `src/lumen_lexer.zig`.
- [x] C4.2 Add precedence levels and parse them in `src/lumen_compiler.zig`.
- [x] C4.3 Integer-operand checks (numeric for `**`) in `src/lumen_check.zig`.
- [x] C4.4 Emit native operators + integer-power helper in
  `src/lumen_compiler.zig`.
- [x] C4.5 Valid bitwise/exponent example + invalid non-integer example +
  manifest.
- [x] C4.6 `zig build` and `zig build conformance` pass.
