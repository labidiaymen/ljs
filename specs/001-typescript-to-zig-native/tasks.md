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
- [x] T011 Add symbol table support for variables and functions.
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
- [x] T033 Accept `if`/`else` block statements with boolean conditions.
- [x] T034 Require boolean `while` conditions.
- [x] T035 Track lexical binding scopes and reject duplicate bindings.
- [x] T036 Reject incompatible arithmetic and comparison operands.
- [x] T037 Parse and emit top-level typed function declarations.
- [x] T038 Check and emit calls to declared functions.
- [x] T039 Check function return statements against declared return types.
- [x] T040 Allow `void` function statement calls and reject void values.
- [x] T041 Predeclare top-level function signatures for hoisted calls.
- [x] T042 Resolve local relative default imports during build.
- [x] T043 Add stable diagnostics for unsupported and missing imports.
- [x] T044 Require simple return completeness for non-void functions.
- [x] T045 Accept bare `return;` only in void functions.
- [x] T046 Lower string equality and inequality to content comparison.
- [x] T047 Accept TypeScript boolean operators and require boolean operands.
- [x] T048 Reject nested function declarations for V1.
- [x] T049 Accept primitive typed arrays, indexing, and length.
- [x] T050 Accept string length and string concatenation.
- [x] T051 Accept V1 Math namespace functions.
- [x] T052 Accept V1 Error, throw, try/catch, and finally.
- [x] T053 Strengthen local modules with default export rewriting, cycle
  checks, and duplicate import diagnostics.
- [x] T055 Add `console.error` to the V1 console surface.
- [x] T056 Extend the V1 Math namespace.
- [x] T057 Add String and Array namespace helpers without prototypes.
- [x] T058 Reject class declarations with a stable V1 diagnostic.
- [x] T059 Add Node-like V1 CLI/file helpers `argsCount()`, `arg(index)`,
  and `fs.readFileSync(path, encoding?)` in `src/lumen_check.zig` and
  `src/lumen_compiler.zig`.
- [x] T060 Add recursive assignability for nested named object literals in
  `src/lumen_check.zig`.
- [x] T061 Add arrays of named object records (`FileScore[]`) to
  `src/lumen_types.zig`, including element typing and generated native type
  names.
- [x] T062 Allow named object values and arrays of named objects to flow through
  function parameters and return statements in `src/lumen_check.zig`.
- [x] T068 Add V1 TypeScript-style `for (let i = init; condition; i = update)`
  loops across `src/lumen_ast.zig`, `src/lumen_compiler.zig`, and
  `src/lumen_check.zig`.
- [x] T070 Add statement-level postfix update and compound assignment syntax
  (`i++`, `i--`, `x += value`, `x -= value`) across `src/lumen_lexer.zig`,
  `src/lumen_ast.zig`, `src/lumen_compiler.zig`, and `src/lumen_check.zig`.
- [x] T017 Reject `eval` with `E_UNSUPPORTED_EVAL`.
- [x] T018 Reject prototype access/mutation with `E_UNSUPPORTED_PROTOTYPE`.
- [x] T019 Reject CommonJS `require` with `E_UNSUPPORTED_COMMONJS`.
- [x] T020 Reject dynamic property writes with `E_DYNAMIC_PROPERTY_WRITE`.

## Phase 5: Showcase Tooling

- [x] T063 Create `packages/context-index` as an npm-style wrapper plus
  Lumen-compiled native scorer.
- [x] T064 Add `examples/context-index-demo` as an agent-oriented sample project
  for build/search demonstrations.
- [x] T065 Batch context-index scoring so the wrapper spawns the native scorer
  once per query instead of once per file.
- [x] T066 Benchmark context-index scoring against a comparable Node scorer and
  record the current Lumen-vs-Node process comparison.

## Phase 6: Verification

- [x] T021 Add conformance manifest cases for valid and invalid examples.
- [x] T022 Verify `zig build`.
- [x] T023 Verify a valid `.ts` example compiles and its binary runs.
- [x] T024 Verify invalid examples fail before generated Zig is emitted.
- [x] T054 Add a manifest-driven conformance runner and `zig build
  conformance` step.
- [x] T067 Add conformance cases for V1 I/O helpers, nested records, arrays of
  records, record return/argument flow, and invalid record-array field
  mismatches.
- [x] T069 Add conformance cases for valid `for` loops and invalid non-boolean
  `for` loop conditions.
- [x] T071 Add conformance cases for postfix update, compound assignment, and
  invalid compound assignment operand types.
- [x] T072 Add conformance cases for TypeScript-style `else if` chains and
  invalid non-boolean `else if` conditions.
- [x] T073 Add statement-level `break;` and `continue;` in loop bodies,
  including invalid outside-loop diagnostics and `for` update preservation.
- [x] T074 Add TypeScript-style ternary expressions with boolean condition
  checking, same-type arm checking, and conformance fixtures.
- [x] T075 Add statement-level prefix update syntax `++name` and `--name`,
  including `for` loop update positions.
- [x] T076 Extend numeric compound assignment to `*=`, `/=`, and `%=`.
- [x] T077 Lower signed integer division and remainder explicitly in generated
  native code and cover them with conformance.
- [x] T078 Add V1 TypeScript-style `switch` statements with typed cases,
  optional default, switch-local `break;`, and conformance fixtures.
- [x] T079 Add TypeScript-style `do...while` loops with boolean condition
  checking and `continue` condition preservation.
