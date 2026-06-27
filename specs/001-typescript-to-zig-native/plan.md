# Implementation Plan: TypeScript Syntax To Generated Zig Native Binary

**Branch**: `001-typescript-to-zig-native` | **Date**: 2026-06-25 |
**Spec**: [spec.md](./spec.md)

## Summary

Pivot the branch from JavaScript engine conformance to a native compiler product:
`.ts` source is parsed, statically checked, lowered to generated Zig, and compiled
to a native executable. The existing `src/lumen_compiler.zig` prototype remains the
implementation seed.

## Technical Context

**Language/Version**: Zig 0.16.0 for the compiler implementation and generated
backend artifact.

**Primary Dependencies**: Zig standard library and host `zig build-exe`.

**Storage**: Source files, generated `.zig` files, native binaries.

**Testing**: `zig build`, focused compiler examples, generated binary execution,
and targeted unit tests where practical.

**Target Platform**: Native CLI executable generation on the developer platform.

**Project Type**: Compiler CLI.

**Performance Goals**: MVP favors correctness and clear diagnostics over
optimization; generated binaries should be small and start quickly.

**Constraints**: Do not use Test262 as a compiler-track gate. Do not expose Zig
as the user-facing language.

**Scale/Scope**: MVP TypeScript syntax subset, not full TypeScript or
JavaScript runtime compatibility.

## Constitution Check

- TypeScript source is the product: pass.
- Backend details stay invisible in user-facing language design: generated Zig is
  an artifact only.
- Node-like APIs require explicit contracts: defer broad stdlib until wrappers
  are specified.
- Examples and conformance are normative: use examples in this spec folder.
- Small predictable V1: pass.

## Project Structure

```text
src/
├── lumen.zig           # compiler CLI, accepts .ts input and builds native binaries
├── lumen_compiler.zig  # compiler orchestration, parser/lowering/emission seed
├── lumen_ast.zig       # expression AST nodes
├── lumen_check.zig     # static checker and variable symbol table
├── lumen_diag.zig      # compiler error and diagnostic types
├── lumen_lexer.zig     # source tokenizer
└── lumen_types.zig     # V1 type representation, aliases, and Zig emission names

specs/001-typescript-to-zig-native/
├── spec.md
├── plan.md
├── tasks.md
├── examples/
│   ├── valid/
│   └── invalid/
└── conformance/
    └── manifest.json

packages/context-index/
├── package.json              # npm-style package metadata
├── bin/context-index.js      # Node wrapper for project walking and CLI UX
├── scripts/build-native.js   # builds the Lumen scorer binary
└── src/score-file.ts         # Lumen source for native file scoring

examples/context-index-demo/
├── README.md
└── src/agent.ts
```

**Structure Decision**: Keep compiler code isolated in its own module path. Do
not route new compiler semantics through the old interpreter/parser conformance
path. Keep compiler files small and split by responsibility as the prototype
grows; do not let `src/lumen_compiler.zig` become a monolith again.

**Legacy Lexer/AST Decision**: The repository still contains the old JavaScript
engine infrastructure in `src/lexer.zig`, `src/ast.zig`, and `src/parser.zig`.
Those modules model ECMAScript tokens, grammar, runtime object behavior,
prototypes, dynamic property/index assignment, modules, classes, and other
semantics that Lumen V1 is deliberately removing. The Lumen compiler therefore
keeps a separate small source scanner and expression representation for now.
Reusable implementation ideas may be borrowed later, but the old JavaScript AST
must not become the semantic contract for the Lumen compiler.

**Node-like Stdlib Decision**: V1 host APIs should follow familiar Node-style
names where possible, but each supported member must be explicitly contracted.
For the current CLI tooling slice, `fs.readFileSync(path, encoding?)` is
supported as a namespaced synchronous text read. The optional encoding argument
is accepted for Node-like call shape and currently treated as UTF-8 text. The
process argument helpers remain minimal (`argsCount()`, `arg(index)`) until a
full `process.argv` record/array surface is specified.

**Records Before Classes Decision**: Named object types are the next object
model milestone before classes. The compiler supports closed record shapes,
nested record fields, arrays of records, indexed record field access, and
record values flowing through function parameters and return statements. Classes
remain out of V1 until constructor, `this`, method, visibility, identity, and
inheritance semantics are designed.

**TypeScript Syntax Iteration Decision**: TypeScript syntax support grows in
small conformance-backed slices. The first loop syntax slice supports
`for (let i = init; condition; i = update) { ... }`, lowering to scoped native
`while` emission. The follow-up update syntax slice supports statement-level
`i++`, `i--`, `++i`, `--i`, and numeric compound assignments for mutable
bindings.
Branch syntax accepts normal TypeScript `else if` chains and lowers them as
nested checked branches.
Loop control accepts TypeScript `break;` and `continue;` inside `while` and
`for`; generated `for` loops use a native loop-update slot so `continue`
preserves TypeScript update semantics.
`do...while` loops preserve TypeScript's body-before-condition behavior and
ensure `continue` reaches the condition check.
Expression syntax accepts TypeScript ternary conditionals with boolean
conditions and same-type arms.
Switch syntax accepts typed `case` labels plus optional `default`, lowered to
isolated native branches without implicit fallthrough for V1.
String literal union aliases erase to native strings while the checker enforces
allowed literal values across assignment, functions, and switch cases.
Destructuring, comma expressions, and value-producing update expressions remain
separate future syntax slices.

**Context Index Showcase Decision**: `packages/context-index` demonstrates the
intended npm integration model: a small Node wrapper handles ecosystem glue
(directory walking, package command UX), while a Lumen-compiled native binary
handles deterministic scoring work. The scorer accepts a batch of file paths per
query to avoid spawning once per file.

## Milestone Strategy

1. Keep `.ts` as the source-facing extension.
2. Split prototype responsibilities into parse, AST, type checking, and Zig
   emission.
3. Implement V1 type and dynamic-feature rejection rules.
4. Add local modules and explicit standard-library wrappers after the core
   checker is stable.
5. Grow records/static objects before classes so tooling examples can model
   structured data without JavaScript prototype semantics.
6. Use medium-complexity npm-style showcase packages to guide practical stdlib
   additions without broad Node compatibility creep.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Generated Zig artifact | Uses Zig as backend quickly | Direct machine code would slow the MVP and duplicate Zig/LLVM work |
