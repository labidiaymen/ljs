# Feature Specification: TypeScript Syntax To Generated Zig Native Binary

**Feature Branch**: `001-typescript-to-zig-native`

**Created**: 2026-06-25

**Status**: Draft

**Input**: User description: "Stop targeting Test262; build a TypeScript-syntax
language that compiles to generated Zig and then to a native binary."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Compile A TypeScript Source File (Priority: P1)

A developer writes a `.ts` source file using the accepted V1 TypeScript syntax
subset and compiles it into a native executable.

**Why this priority**: This is the core product promise.

**Independent Test**: `compile examples/valid/hello.ts` produces a native
executable that prints the expected output.

**Acceptance Scenarios**:

1. **Given** a `.ts` file containing top-level code and `console.log`, **When**
   the compiler runs, **Then** it emits generated Zig and produces a native
   binary.
2. **Given** a `.ts` file containing integer arithmetic, **When** the binary is
   executed, **Then** it prints the computed result.

---

### User Story 2 - Keep JavaScript Dynamism Out (Priority: P1)

A developer receives clear diagnostics when source uses dynamic JavaScript
features that cannot belong to a predictable native compiler.

**Why this priority**: Native compilation depends on fixed static semantics.

**Independent Test**: Invalid examples using `eval`, prototype mutation, or
CommonJS fail before Zig generation.

**Acceptance Scenarios**:

1. **Given** source containing `eval`, **When** checked, **Then**
   `E_UNSUPPORTED_EVAL` is reported.
2. **Given** source containing `String.prototype.x = ...`, **When** checked,
   **Then** `E_UNSUPPORTED_PROTOTYPE` is reported.
3. **Given** source containing `require("fs")`, **When** checked, **Then**
   `E_UNSUPPORTED_COMMONJS` is reported.

---

### User Story 3 - Use Familiar Static Types (Priority: P2)

A developer uses TypeScript syntax with Lumen numeric spellings such as `int`
and `i32`.

**Why this priority**: The language should feel close to TypeScript while still
being precise enough for native output.

**Independent Test**: Valid examples using `let a = 4`, `int`, `i32`, `number`,
`boolean`, and `string` type-check and lower to Zig.

**Acceptance Scenarios**:

1. **Given** `let a = 4`, **When** checked, **Then** `a` is inferred as `int`.
2. **Given** `let x: i32 = 4`, **When** checked, **Then** the type is accepted.
3. **Given** assignment of a string to an integer variable, **When** checked,
   **Then** `E_TYPE_MISMATCH` is reported.
4. **Given** `type User = { id: int }` and `let user: User = { id: 7 }`,
   **When** checked, **Then** the object literal is accepted as `User` and
   `user.id` is typed as `int`.
5. **Given** `let total = 1` followed by `total = total + 2`, **When**
   checked, **Then** reassignment is accepted.
6. **Given** `const total = 1` followed by `total = 2`, **When** checked,
   **Then** `E_CONST_ASSIGNMENT` is reported.
7. **Given** `console.log` receives a string, boolean, or numeric value,
   **When** emitted, **Then** the generated native program prints it using the
   checked source type.
8. **Given** `true` or `false` appears in an expression, **When** parsed,
   **Then** it is treated as a boolean literal rather than a variable name.
9. **Given** an `if` statement with a boolean condition, **When** compiled,
   **Then** the native program executes the matching block.
10. **Given** an `if` statement with a non-boolean condition, **When** checked,
    **Then** `E_TYPE_MISMATCH` is reported.
11. **Given** a `while` statement with a non-boolean condition, **When**
    checked, **Then** `E_TYPE_MISMATCH` is reported.
12. **Given** two declarations with the same name in the same lexical scope,
    **When** checked, **Then** `E_DUPLICATE_BINDING` is reported.
13. **Given** a block declares a name that exists in an outer scope, **When**
    checked, **Then** the inner declaration shadows only within that block.
14. **Given** arithmetic or ordered comparison operands with incompatible
    types, **When** checked, **Then** `E_TYPE_MISMATCH` is reported.
15. **Given** a top-level typed function declaration with typed parameters and
    a declared return type, **When** compiled, **Then** it is emitted into the
    generated native artifact.
16. **Given** a call to a declared function, **When** checked, **Then** argument
    count and argument types must match the function signature.

### Edge Cases

- Generated Zig is allowed to exist on disk, but it is not the source language.
- The old JavaScript interpreter/Test262 conformance path is not a V1 compiler
  requirement.
- `.ts` is the V1 source extension.
- Remote packages and package manager behavior are out of scope.
- Standard-library wrappers should be designed explicitly rather than inherited
  wholesale from Node or the old runtime.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The compiler MUST accept `.ts` files as the primary source input.
- **FR-002**: The compiler MUST lower accepted source to generated Zig before
  invoking native compilation.
- **FR-003**: The compiler MUST produce a native executable for valid MVP
  programs.
- **FR-004**: The source language MUST use TypeScript syntax, not a new custom
  surface syntax.
- **FR-005**: The checker MUST infer `let a = 4` as `int`.
- **FR-006**: The checker MUST accept both `int` and `i32` for 32-bit signed
  integer values.
- **FR-007**: The compiler MUST reject `eval`.
- **FR-008**: The compiler MUST reject prototype access and prototype mutation.
- **FR-009**: The compiler MUST reject CommonJS `require`.
- **FR-010**: The compiler MUST reject dynamic object shape mutation.
- **FR-011**: Generated Zig paths, diagnostics, and panic mapping MUST point back
  to the original `.ts` source when possible.
- **FR-012**: The compiler track MUST NOT use Test262 conformance as a product
  requirement.
- **FR-013**: Remote packages, package managers, and raw URL/GitHub imports MUST
  be excluded from this V1 compiler slice.
- **FR-014**: Named object type declarations MUST define closed static shapes.
  Object literals assigned to those names MUST provide exactly the declared
  fields with compatible field types.
- **FR-015**: `let` declarations MUST create reassignable bindings and `const`
  declarations MUST create non-reassignable bindings.
- **FR-016**: `console.log` emission MUST use the checked argument type rather
  than assuming every argument is an integer.
- **FR-017**: The compiler MUST accept `true` and `false` as boolean literals.
- **FR-018**: The compiler MUST accept TypeScript-style `if`/`else` block
  statements and require their conditions to be boolean.
- **FR-019**: The compiler MUST require `while` conditions to be boolean.
- **FR-020**: `let`, `const`, and `var` declarations MUST be tracked in
  lexical scopes, reject duplicate declarations in the same scope, and allow
  shadowing in nested block scopes.
- **FR-021**: Arithmetic operators MUST require compatible numeric operands.
- **FR-022**: Ordered comparison operators MUST require compatible numeric
  operands; equality operators MUST require compatible operand types.
- **FR-023**: The compiler MUST accept top-level TypeScript-style function
  declarations with typed parameters, an explicit return type, and block bodies.
- **FR-024**: Function calls MUST check argument count and argument types against
  the declared function signature.

### Diagnostics

- **E_UNSUPPORTED_EVAL**: Produced when source uses `eval`.
- **E_UNSUPPORTED_PROTOTYPE**: Produced when source reads or writes prototype
  mutation surfaces.
- **E_UNSUPPORTED_COMMONJS**: Produced when source uses `require`.
- **E_DYNAMIC_PROPERTY_WRITE**: Produced when source writes a property not
  declared by the target object type.
- **E_TYPE_MISMATCH**: Produced when assigned value type is incompatible with
  the declared or inferred variable type.
- **E_CONST_ASSIGNMENT**: Produced when source attempts to assign a new value to
  a `const` binding.
- **E_DUPLICATE_BINDING**: Produced when a declaration repeats a name already
  declared in the same lexical scope.
- **E_ARG_COUNT**: Produced when a function call provides the wrong number of
  arguments.

### Existing JavaScript Infrastructure

This repository already contains a mature JavaScript lexer, parser, and AST for
the legacy engine path. Lumen V1 does not use those modules as its language
contract because they encode JavaScript semantics that are out of scope for this
compiled language, including prototypes, dynamic object shapes, CommonJS-era
runtime behavior, and broad ECMAScript grammar. Lumen compiler modules may reuse
ideas from that code, but accepted source behavior is defined by this spec and
the Lumen compiler track.

### Key Entities

- **Source program**: A `.ts` file written in the accepted TypeScript syntax
  subset.
- **Generated Zig artifact**: Compiler output used to produce the native binary.
- **Native binary**: The executable produced by the host Zig compiler.
- **Static checker**: Compiler phase that assigns and validates fixed source
  types before code generation.
- **Named object type**: A TypeScript-style `type` declaration whose object
  fields define a closed native shape for checking and code generation.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A valid `.ts` hello program compiles to a native executable and
  prints the expected output.
- **SC-002**: At least three unsupported dynamic JavaScript examples fail before
  generated Zig is emitted.
- **SC-003**: At least one typed arithmetic example verifies `int`/`i32`
  behavior.
- **SC-004**: Project docs describe the branch as TypeScript-to-Zig-to-binary,
  not as a Test262 conformance effort.

## Assumptions

- Zig remains the native backend for this branch.
- The existing `src/lumen_compiler.zig` prototype is the starting
  implementation, but its single-pass shape may change.
- Existing ljs runtime code can remain in the repo while the active product track
  moves to the compiler.
