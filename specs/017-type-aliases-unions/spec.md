# Feature Specification: Type Aliases, Discriminated Unions, and `as`

**Feature Branch**: `tjs-native` (milestone 017) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Support `type X = ...` aliases over existing types, discriminated
unions whose variants are record types sharing a string-literal discriminant
field, tag-based narrowing in `switch` and `if`, and `as` type assertions for
the safe/checked subset.

## Scope (V1)

- **Type aliases**: `type Id = int;`, `type Name = string;`, `type Nums = int[];`,
  `type MaybeName = string?;`, `type P = Point;` — an alias names any already
  spellable type. Aliases resolve transitively and are interchangeable with the
  type they name.
- **Discriminated unions**: `type Shape = Circle | Square;` where each named
  variant is a previously declared record type and every variant carries a common
  discriminant field annotated with a string-literal type
  (e.g. `kind: "circle"`). The union value holds exactly one variant at a time.
- **Narrowing**: inside a `switch (s.kind)` case, or an
  `if (s.kind === "circle")` then-branch, the union binding `s` narrows to the
  matching variant so that variant-specific fields become accessible.
- **`as` assertions**: `expr as T` for the safe, representation-preserving subset
  — an identity cast, an alias to/from its underlying type, or literal-union
  widening (`"a" | "b"` to `string`, `1 | 2` to `int`). Unrelated casts
  (e.g. `string as int`) are rejected.

Out of scope this cycle: unions of scalars (`int | string`), unions without a
shared string-literal discriminant, exhaustiveness checking across all variants,
intersection types, `as const`, and double-assertions through `unknown`.

## Requirements

- **FR-001**: `type X = <annotation>;` declares an alias usable anywhere a type
  annotation is accepted; the alias resolves to its target type for all checks.
- **FR-002**: A discriminated union variant must be a declared record type whose
  discriminant field is a string-literal type; all variants must share the same
  discriminant field name. Violations report `E_TYPE_MISMATCH`.
- **FR-003**: An object literal or value is assignable to a union when it matches
  exactly one variant. A field access on an un-narrowed union value is limited to
  the shared discriminant field; accessing a variant-only field reports
  `E_TYPE_MISMATCH`.
- **FR-004**: A `switch` on the discriminant field, or an `if` testing the
  discriminant with `===`/`==`, narrows the union binding to the matching variant
  within that branch, enabling variant field access.
- **FR-005**: `expr as T` yields type `T` when the assertion is within the safe,
  representation-preserving subset (identity, alias <-> underlying, or
  literal-union widening); an unrelated assertion reports `E_TYPE_MISMATCH`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_DUPLICATE_BINDING`.

## Success Criteria

- **SC-001**: A program using aliases and a discriminated-union `switch` compiles
  and the produced native binary prints the expected results.
- **SC-002**: Accessing a variant-only field on an un-narrowed union, a bad
  discriminant narrowing, and an illegal `as` cast each fail before native build.
- **SC-003**: `zig build conformance` passes with the feature 017 manifest.

## Notes

Aliases are erased: they resolve to their target before emission. A discriminated
union lowers to a single flat Zig struct holding the discriminant plus the union
of every variant's fields, with defaulted fields so a single-variant object
literal initializes cleanly. Narrowing is a checker-only concept: because every
field lives in the flat struct, field access emits unchanged regardless of the
narrowed variant. `as` is erased to its operand expression.
</content>
