# Feature Specification: Nullability

**Feature Branch**: `tjs-native` (milestone 004) | **Created**: 2026-06-27 |
**Status**: Draft

**Input**: Add the single highest-value "feels like TypeScript" capability:
optional values. This is the first architecture-touching milestone — it adds an
optional wrapper to the type representation and a limited flow-sensitive
narrowing pass. Lowers to Zig optionals (`?T`).

## Scope (3 cycles)

5. **`null`/`undefined` + nullable types** (`T | null`, `T | undefined`).
6. **Optional `?` fields/params + `??`** nullish coalescing.
7. **`?.` optional chaining + narrowing** (`if (x != null) { ... }`).

`null` and `undefined` are unified to a single absent value lowering to Zig
`null`. Out of scope: distinguishing null from undefined, definite-assignment
analysis, and narrowing patterns beyond `if (x != null)` / `if (x == null)`.

## Requirements

- **FR-001**: `let x: T | null` and `let x: T | undefined` declare an optional
  binding accepting either a `T` value or the absent value.
- **FR-002**: The `null` and `undefined` literals are accepted and assignable to
  any optional binding, parameter, field, or return type.
- **FR-003**: Assigning the absent value to a non-optional type MUST report
  `E_TYPE_MISMATCH`.
- **FR-004**: An optional field `name?: T` is equivalent to `name: T | undefined`
  and object literals MAY omit it (it defaults to absent).
- **FR-005**: An optional parameter `name?: T` is equivalent to `name: T |
  undefined`.
- **FR-006**: `a ?? b` returns `a` when present and `b` otherwise; `a` MUST be
  optional and `b` MUST be assignable to the non-optional element type. Result
  type is the non-optional element type.
- **FR-007**: `a?.field` on an optional named value returns the field type made
  optional, and evaluates to absent when `a` is absent.
- **FR-008**: Using an optional value directly where its non-optional type is
  required (arithmetic, field access, function arg) MUST report
  `E_TYPE_MISMATCH` unless it has been narrowed.
- **FR-009**: Inside `if (x != null)` / `if (x !== null)` /
  `if (x != undefined)` the binding `x` MUST be narrowed to its non-optional type
  in the then-branch; `if (x == null) { ... } else { ... }` narrows `x` in the
  else-branch.

### Diagnostics

Reuses `E_TYPE_MISMATCH`.

## Success Criteria

- **SC-001**: A program with an optional binding, `??`, `?.`, and an
  `if (x != null)` narrow compiles and prints expected output.
- **SC-002**: Using an un-narrowed optional as a plain value fails before Zig
  emission.
- **SC-003**: `zig build conformance` passes with the feature 004 manifest.
