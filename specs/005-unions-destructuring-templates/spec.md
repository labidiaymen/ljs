# Feature Specification: Unions, Destructuring, Template Literals

**Feature Branch**: `tjs-native` (milestone 005) | **Created**: 2026-06-27 |
**Status**: Draft

**Input**: The final roadmap milestone. Three cycles, each scoped to a solid V1
that lowers cleanly to Zig.

## Scope (3 cycles)

8. **Numeric literal unions + `typeof`-free literal narrowing.** Generalize the
   existing string-literal-union machinery to numeric literal unions
   (`type Code = 200 | 404 | 500`). Values must be one of the declared literals;
   switch/equality narrowing already applies. (General record/tagged unions
   remain future work.)
9. **Destructuring.** Array destructuring `let [a, b] = arr;` and object
   destructuring `let { x, y } = point;` for already-typed sources, lowered to
   per-binding declarations.
10. **Template literals.** `` `text ${expr} more` `` lowered to string
    concatenation, with interpolation of string and numeric expressions.

Out of scope: general tagged/record unions, nested/rest destructuring patterns,
default values in patterns, and tagged template functions.

## Requirements

- **FR-001**: `type Name = N1 | N2 | ...` with integer literals declares a numeric
  literal union; values assigned to it (binding, parameter, return, switch case)
  MUST be one of the declared literals, else `E_TYPE_MISMATCH`.
- **FR-002**: A numeric literal union erases to its integer backing type for
  emission and arithmetic-free comparison.
- **FR-003**: `let [a, b] = arrExpr;` binds `a`, `b` to the array element type by
  position; the source MUST be an array.
- **FR-004**: `let { x, y } = objExpr;` binds `x`, `y` to the matching field
  types; the source MUST be a named record with those fields.
- **FR-005**: Destructuring bindings honor `let`/`const` mutability and create
  loop/block-scoped bindings like ordinary declarations.
- **FR-006**: A template literal `` `a${e}b` `` produces a `string`; each `${}`
  hole accepts a `string` or numeric expression and is converted to text.
- **FR-007**: A template literal with no holes is equivalent to a string literal.

### Diagnostics

Reuses `E_TYPE_MISMATCH`.

## Success Criteria

- **SC-001**: A numeric-literal-union program compiles, accepts valid literals,
  and rejects out-of-set values.
- **SC-002**: Array and object destructuring programs compile and print the
  destructured values.
- **SC-003**: A template-literal program prints interpolated text.
- **SC-004**: `zig build conformance` passes with the feature 005 manifest.
