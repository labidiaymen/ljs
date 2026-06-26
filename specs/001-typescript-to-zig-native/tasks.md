# Tasks: TypeScript Syntax To Generated Zig Native Binary

**Input**: `spec.md`, `plan.md`

## Phase 1: Spec Pivot

- [x] T001 Remove legacy ljs/Test262 spec folders from this branch.
- [x] T002 Create clean TypeScript-to-Zig-to-binary spec folder.
- [x] T003 Update README and agent context to stop describing this branch as
  Test262-driven.

## Phase 2: Source Identity

- [x] T004 Make the default build install a compiler-first executable instead
  of the legacy JS runtime.
- [x] T005 Add `src/lumen.zig` as a compiler-only CLI for `.ts` input.
- [x] T006 Update `src/lumen_compiler.zig` diagnostics and embedded source labels to
  `.ts`.
- [x] T007 Add valid `.ts` examples under this spec folder.
- [x] T008 Add invalid dynamic-JS `.ts` examples under this spec folder.

## Phase 3: Compiler Pipeline

- [x] T025 Split diagnostic, AST, type-helper, and lexer code out of
  `src/lumen_compiler.zig` into focused compiler modules.
- [x] T026 Rename compiler modules and generated helper prefixes from the old
  track naming to Lumen naming.
- [x] T027 Document why Lumen uses compiler-specific scanner/IR modules instead
  of the legacy JavaScript lexer/AST as its semantic contract.
- [x] T009 Introduce a statement/expression AST separate from immediate Zig
  emission.
- [x] T010 Introduce a type representation for `int`, `i32`, `number`, `float`,
  `boolean`, `string`, and `void`.
- [ ] T011 Add symbol table support for variables and functions.
- [x] T028 Add checker-owned variable symbol table support.
- [x] T012 Add static checker pass before Zig emission.
- [x] T013 Keep generated Zig emission as a distinct phase.

## Phase 4: V1 Semantics

- [x] T014 Accept `let a = 4` with inferred `int`.
- [x] T015 Accept explicit `int` and `i32` annotations.
- [x] T016 Reject incompatible reassignment with `E_TYPE_MISMATCH`.
- [x] T029 Check named object type declarations, object literals, and field
  access.
- [x] T030 Match TypeScript-inspired `let`/`const` binding mutability.
- [x] T031 Emit `console.log` using the checked argument type.
- [x] T032 Accept `true` and `false` boolean literals.
- [x] T017 Reject `eval` with `E_UNSUPPORTED_EVAL`.
- [x] T018 Reject prototype access/mutation with `E_UNSUPPORTED_PROTOTYPE`.
- [x] T019 Reject CommonJS `require` with `E_UNSUPPORTED_COMMONJS`.
- [x] T020 Reject dynamic property writes with `E_DYNAMIC_PROPERTY_WRITE`.

## Phase 5: Verification

- [x] T021 Add conformance manifest cases for valid and invalid examples.
- [x] T022 Verify `zig build`.
- [x] T023 Verify a valid `.ts` example compiles and its binary runs.
- [x] T024 Verify invalid examples fail before generated Zig is emitted.
