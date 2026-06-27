# Feature Specification: Numeric Literals And Lexer Completeness

**Feature Branch**: `tjs-native` (milestone 002)

**Created**: 2026-06-27

**Status**: Draft

**Input**: Close the highest-leverage, non-architecture-breaking gaps in the V1
lexer so the accepted TypeScript syntax surface grows without touching the type
or lowering model. The V1 type system already names `number`/`float`/`f64`, but
the lexer can only produce base-10 integers, so float source can never be
written. This milestone makes the lexer match the types that already exist and
adds the remaining everyday literal/operator/comment forms.

## Scope (4 cycles)

This feature is delivered in four small, conformance-backed cycles:

1. **Decimal/float literals** — fractional and exponent number literals lower to
   `f64`/`number`.
2. **Non-decimal integer bases and digit separators** — `0x`, `0o`, `0b`, and
   `_` separators for integer literals.
3. **Block comments** — `/* ... */` comments are skipped like `//` comments.
4. **Strict equality operators** — `===` and `!==` are accepted and lower
   identically to `==`/`!=` (statically typed operands make them equivalent).

Out of scope: `BigInt` literals (`1n`), template literals, regex literals, and
any change to the type representation or lowering pipeline.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Write Floating-Point Numbers (Priority: P1)

A developer writes fractional numbers and the checker types them as `number`
(`f64`), consistent with the existing numeric type spellings.

**Why this priority**: The type system already promises `number`/`float`/`f64`,
but no float value can currently be lexed. This is a correctness gap, not just a
missing convenience.

**Independent Test**: `let pi: number = 3.14;` type-checks and the native binary
prints the value.

**Acceptance Scenarios**:

1. **Given** `let x = 3.14`, **When** checked, **Then** `x` is inferred as
   `number` (`f64`).
2. **Given** `1.5e3` or `2e-2`, **When** lexed, **Then** they are accepted as
   float literals.
3. **Given** a float value assigned to an `int`/`i32` binding, **When** checked,
   **Then** `E_TYPE_MISMATCH` is reported.
4. **Given** `console.log(3.5)`, **When** emitted, **Then** the native program
   prints the float using its checked `number` type.

---

### User Story 2 - Write Integers In Common Bases (Priority: P2)

A developer writes hexadecimal, octal, and binary integer literals and uses
underscore separators for readability.

**Independent Test**: `let mask = 0xFF;` and `let big = 1_000_000;` type-check as
`int` and print their decimal value.

**Acceptance Scenarios**:

1. **Given** `0xFF`, `0o17`, `0b1010`, **When** lexed, **Then** they are
   accepted as integer literals with the correct value.
2. **Given** `1_000_000` or `0xFF_FF`, **When** lexed, **Then** separators are
   ignored and the literal keeps its integer type.
3. **Given** a malformed literal such as `0x` with no digits, **When** lexed,
   **Then** a stable diagnostic is reported.

---

### User Story 3 - Use Block Comments (Priority: P3)

A developer uses `/* ... */` comments, including multi-line, around V1 source.

**Independent Test**: A program with block comments compiles and runs as if the
comments were absent.

**Acceptance Scenarios**:

1. **Given** `/* note */ let a = 1;`, **When** lexed, **Then** the comment is
   skipped.
2. **Given** a multi-line `/* ... */` spanning several lines, **When** lexed,
   **Then** line tracking remains correct for later diagnostics.

---

### User Story 4 - Use Strict Equality (Priority: P3)

A developer writes idiomatic TypeScript `===` and `!==`.

**Independent Test**: `if (a === b)` and `if (a !== b)` compile and behave like
`==`/`!=` over statically typed operands.

**Acceptance Scenarios**:

1. **Given** `a === b` with same-typed operands, **When** checked, **Then** it is
   accepted and lowers to the same comparison as `a == b`.
2. **Given** `a !== b`, **When** checked, **Then** it lowers like `a != b`,
   including string content comparison for string operands.

### Edge Cases

- A `.` that follows digits is a fractional point only when the number context
  applies; member access like `arr.length` is unaffected because `length` does
  not begin with a digit.
- A leading-dot float (`.5`) and trailing-dot float (`5.`) are out of scope for
  this milestone; require a digit on both sides (`0.5`, `5.0`).
- Numeric separators must sit between digits, not lead, trail, or repeat.
- Block comments do not nest (TypeScript semantics): the first `*/` closes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The lexer MUST accept decimal float literals of the form
  `<digits>.<digits>` with an optional exponent `e`/`E` and optional sign.
- **FR-002**: Float literals MUST be typed as `number` (`f64`) by the checker and
  inferred as `number` when used to initialize a binding without annotation.
- **FR-003**: Assigning a float literal to an integer (`int`/`i32`/`i64`) binding
  MUST report `E_TYPE_MISMATCH`.
- **FR-004**: `console.log` MUST print float values using the checked `number`
  type.
- **FR-005**: The lexer MUST accept hexadecimal (`0x`/`0X`), octal (`0o`/`0O`),
  and binary (`0b`/`0B`) integer literals and produce their integer value.
- **FR-006**: The lexer MUST accept `_` digit separators inside decimal and
  non-decimal integer literals and inside float literals, ignoring them in the
  parsed value.
- **FR-007**: A malformed numeric literal (a base prefix with no following
  digits) MUST report `E_INVALID_NUMBER`.
- **FR-008**: The lexer MUST skip `/* ... */` block comments, including
  multi-line comments, while keeping source line/column tracking correct.
- **FR-009**: An unterminated block comment MUST report `E_INVALID_NUMBER`'s
  sibling lexer diagnostic `E_UNTERMINATED_COMMENT`.
- **FR-010**: The lexer MUST accept `===` and `!==` operators.
- **FR-011**: `===` MUST type-check and lower identically to `==`, and `!==`
  identically to `!=`, including string content comparison for string operands.

### Diagnostics

- **E_INVALID_NUMBER**: Produced when a numeric literal is malformed (e.g. a
  base prefix `0x`/`0o`/`0b` with no digits, or a separator in an illegal
  position).
- **E_UNTERMINATED_COMMENT**: Produced when a `/*` block comment has no closing
  `*/` before end of file.

### Key Entities

- **Float literal**: A source numeric literal with a fractional part and/or
  exponent, typed `number` (`f64`).
- **Integer literal**: A source numeric literal in decimal, hex, octal, or
  binary, typed `int` (`i32`) unless annotated otherwise.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A valid `.ts` program using float literals compiles to a native
  binary and prints the expected float output.
- **SC-002**: A valid `.ts` program using hex/octal/binary/separator integer
  literals compiles and prints the expected decimal values.
- **SC-003**: A program using multi-line block comments compiles and runs.
- **SC-004**: `===`/`!==` programs compile and behave like `==`/`!=`.
- **SC-005**: Invalid cases (float→int mismatch, malformed literal,
  unterminated comment) fail before generated Zig is emitted.
- **SC-006**: `zig build conformance` passes with the new cases added to the
  feature 002 manifest.

## Assumptions

- The type representation (`src/lumen_types.zig`) and lowering pipeline remain
  unchanged; only the lexer, AST literal nodes, checker inference, and emission
  for the new literal forms are touched.
- `f64` already exists end-to-end as a type; this milestone only makes float
  *values* reachable from source.
