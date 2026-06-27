# Implementation Plan: Iteration, Enums, Interfaces, And Operators

**Branch**: `tjs-native` | **Date**: 2026-06-27 | **Spec**: [spec.md](./spec.md)

## Summary

Four additive cycles continuing the cheap lane from feature 002. Each reuses
existing infrastructure: `for...of` reuses the scoped `while`/index lowering,
`enum` reuses named-type plumbing with a new backing-value table, `interface`
reuses the object-type declaration path, and the new operators reuse the numeric
binary expression path.

## Affected Modules

- `src/lumen_lexer.zig` — new operator tokens: `&`, `|`, `^`, `~`, `<<`, `>>`,
  `**`. (`&&`/`||` already handled; single `&`/`|` and shifts are new.)
- `src/lumen_ast.zig` — `for_of` statement, `enum_decl` statement, enum member
  access nodes / reuse of `field`; bitwise/exponent reuse `bin`.
- `src/lumen_types.zig` — `enum_type: []const u8` variant; `inferExprType` and
  emission names.
- `src/lumen_check.zig` — type the new forms; enum member resolution; iterable
  checking; integer-operand checks for bitwise/shift.
- `src/lumen_compiler.zig` — parse `for...of`, `enum`, `interface`; emit index
  `while` for `for...of`, constants for enum members, native operators.
- `build.zig` — wire `specs/003-iteration-enums-ops/conformance/manifest.json`.

## Cycle Breakdown

### Cycle 1 — `for...of` (P1)

Parser: in the `for (` path, after the binding name, detect the `of` keyword and
branch to a `for...of` form instead of the C-style `;`-separated form. AST: add
`for_of { binding, iterable, body }`. Checker: iterable must be array or string;
bind the loop variable to the element type in a new scope. Compiler: lower to a
hidden index counter + `while (i < iterable.length)` with the binding assigned
from `iterable[i]`, preserving `break`/`continue` (continue must still bump the
index — reuse the existing for-update slot mechanism).

### Cycle 2 — `enum` (P2)

Parser: `enum Name { A, B = 2, C }` and string members. AST: `enum_decl` with
members + backing values. Types: `enum_type` variant. Checker: register the enum
name; `Enum.Member` resolves to the enum type; equality between same-enum values
allowed; raw int/string assignment to an enum binding is `E_TYPE_MISMATCH`.
Compiler: emit each member as its backing constant where referenced.

### Cycle 3 — `interface` (P3)

Parser: accept `interface Name { fields }` and construct the same `TypeDecl` the
`type Name = { ... }` path builds. No checker/emit change beyond sharing the
named-type table.

### Cycle 4 — Bitwise + exponent (P4)

Lexer: emit tokens for `&`, `|`, `^`, `~`, `<<`, `>>`, `**`. Parser: add
precedence levels (TS order: `**` tightest among these; bitwise below
comparison: `|` < `^` < `&` < shift). Checker: integer-only operands for
bitwise/shift; numeric for `**`. Compiler: emit native Zig operators; `**` via a
small integer-power helper.

## Verification Per Cycle

Each cycle ends with: `zig build`, a valid example that compiles and runs, an
invalid example with the expected diagnostic, and `zig build conformance`.

## Complexity Tracking

| Decision | Why | Rejected Alternative |
|----------|-----|----------------------|
| `for...of` lowers to index `while` | Reuses proven loop lowering; no iterator protocol | A real iterator interface needs closures/heap, out of scope |
| Enum as closed `enum_type` variant | Keeps the type set closed; no union machinery | General unions are a later (004/005) architecture step |
| `interface` aliases `type` object decl | Zero semantic divergence, max familiarity | A separate interface entity would duplicate checking |
| `**` via helper, integer power | Zig has no `**`; keeps integer semantics | Float `pow` only would change integer results |
