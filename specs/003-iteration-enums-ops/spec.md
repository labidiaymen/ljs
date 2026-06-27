# Feature Specification: Iteration, Enums, Interfaces, And Operators

**Feature Branch**: `tjs-native` (milestone 003)

**Created**: 2026-06-27

**Status**: Draft

**Input**: Continue growing the accepted TypeScript surface in the cheap,
additive lane established by feature 002. None of these cycles require closures,
a heap model, or type narrowing; they reuse the existing array/length, named-type,
and numeric-binary infrastructure.

## Scope (4 cycles)

1. **`for...of`** iteration over arrays and strings, lowered to an index `while`.
2. **`enum`** declarations (numeric and string), erased to native constants.
3. **`interface`** as a synonym for object `type` declarations.
4. **Bitwise and exponent operators** (`& | ^ ~ << >>`, `**`) for integers.

Out of scope: iterators/generators, `for...in`, `const enum` semantics beyond
plain erasure, interface extension/merging, and operator overloading.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Iterate With `for...of` (Priority: P1)

A developer iterates the elements of an array or the characters of a string.

**Independent Test**: `for (const x of nums) { ... }` compiles and the native
binary visits each element in order.

**Acceptance Scenarios**:

1. **Given** `let nums: int[] = [1,2,3]` and `for (const n of nums)`, **When**
   compiled, **Then** the body runs once per element with `n` typed as the
   element type.
2. **Given** iteration over a `string`, **When** compiled, **Then** the loop
   binding is typed as `string` (single-character substring) per iteration.
3. **Given** `for...of` over a non-iterable (e.g. an `int`), **When** checked,
   **Then** `E_TYPE_MISMATCH` is reported.
4. **Given** `break;`/`continue;` inside a `for...of` body, **When** compiled,
   **Then** they behave as in other loops.

---

### User Story 2 - Declare Enums (Priority: P2)

A developer declares named enums and uses their members as values.

**Independent Test**: `enum Color { Red, Green, Blue }` and `Color.Green`
type-check and the program prints the backing value.

**Acceptance Scenarios**:

1. **Given** a numeric `enum` with no initializers, **When** checked, **Then**
   members auto-number from 0 and `Enum.Member` is typed as that enum.
2. **Given** a string `enum` (`enum Dir { Up = "up" }`), **When** checked,
   **Then** members carry their string value.
3. **Given** an enum value compared with `==`/`===` to another member of the
   same enum, **When** checked, **Then** it is accepted.
4. **Given** assignment of a raw int/string to an enum-typed binding, **When**
   checked, **Then** `E_TYPE_MISMATCH` is reported.

---

### User Story 3 - Declare Interfaces (Priority: P3)

A developer uses `interface` instead of `type` for object shapes.

**Independent Test**: `interface User { id: int }` behaves exactly like
`type User = { id: int }`.

**Acceptance Scenarios**:

1. **Given** `interface User { id: int }` and `let u: User = { id: 7 }`, **When**
   checked, **Then** the object literal is accepted as `User`.
2. **Given** an interface used as a function parameter/return type, **When**
   checked, **Then** it behaves like the equivalent named object type.

---

### User Story 4 - Bitwise And Exponent Operators (Priority: P3)

A developer uses integer bitwise and exponent operators.

**Independent Test**: `5 & 3`, `1 << 4`, `2 ** 10` compute the expected values.

**Acceptance Scenarios**:

1. **Given** `a & b`, `a | b`, `a ^ b`, `~a`, `a << b`, `a >> b` with integer
   operands, **When** compiled, **Then** they compute the native integer result.
2. **Given** `a ** b` with integer operands, **When** compiled, **Then** it
   computes integer exponentiation.
3. **Given** a bitwise/shift operator with a non-integer operand, **When**
   checked, **Then** `E_TYPE_MISMATCH` is reported.

### Edge Cases

- `for...of` requires an array or string operand; numbers/booleans are rejected.
- Enum member access uses dot syntax only; computed member access is out of scope.
- Interface and type names share one namespace; a duplicate name is a binding
  error.
- Shift and bitwise operators are integer-only; floats are rejected.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The compiler MUST accept `for (const name of iterable) { ... }` and
  `for (let name of iterable) { ... }` over array and string operands.
- **FR-002**: The `for...of` binding MUST be typed as the array element type, or
  `string` when iterating a string, and MUST be loop-scoped.
- **FR-003**: `for...of` over a non-array, non-string operand MUST report
  `E_TYPE_MISMATCH`.
- **FR-004**: `break;` and `continue;` MUST work inside `for...of` bodies.
- **FR-005**: The compiler MUST accept `enum` declarations with auto-numbered
  members (from 0) and explicit numeric or string initializers.
- **FR-006**: `Enum.Member` access MUST be typed as the enum type and lower to
  the member's backing value.
- **FR-007**: Enum-typed values MUST compare equal/not-equal against members of
  the same enum; assigning a raw int/string to an enum binding MUST report
  `E_TYPE_MISMATCH`.
- **FR-008**: The compiler MUST accept `interface Name { ... }` as a synonym for
  `type Name = { ... }`, sharing the named-type namespace.
- **FR-009**: The compiler MUST accept integer bitwise operators `&`, `|`, `^`,
  `~` (unary), `<<`, `>>` with integer operands, rejecting non-integers with
  `E_TYPE_MISMATCH`.
- **FR-010**: The compiler MUST accept the exponent operator `**` with numeric
  operands, computing integer exponentiation for integer operands.

### Diagnostics

- Reuses existing `E_TYPE_MISMATCH`, `E_DUPLICATE_BINDING`,
  `E_BREAK_OUTSIDE_LOOP`, `E_CONTINUE_OUTSIDE_LOOP`.

### Key Entities

- **Iterable**: An array or string operand of a `for...of` loop.
- **Enum**: A named set of constant members with a numeric or string backing
  type.
- **Interface**: A named object shape, equivalent to a `type` object alias.

## Success Criteria *(mandatory)*

- **SC-001**: A `for...of` program over an array and a string compiles and prints
  each element/character.
- **SC-002**: An enum program prints member backing values and rejects raw
  assignment.
- **SC-003**: An interface program behaves identically to the `type` equivalent.
- **SC-004**: A bitwise/exponent program computes the expected integer results.
- **SC-005**: Invalid cases (non-iterable `for...of`, enum mismatch, non-integer
  bitwise) fail before generated Zig is emitted.
- **SC-006**: `zig build conformance` passes with the feature 003 manifest.

## Assumptions

- The type representation gains an enum entry but stays a closed set; no general
  union/narrowing work is required for this milestone.
- `for...of` lowers to the existing scoped `while` + index pattern; no iterator
  protocol is introduced.
