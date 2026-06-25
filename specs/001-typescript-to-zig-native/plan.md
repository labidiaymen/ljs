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
└── lumen_types.zig     # V1 type aliases and expression type inference

specs/001-typescript-to-zig-native/
├── spec.md
├── plan.md
├── tasks.md
├── examples/
│   ├── valid/
│   └── invalid/
└── conformance/
    └── manifest.json
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

## Milestone Strategy

1. Keep `.ts` as the source-facing extension.
2. Split prototype responsibilities into parse, AST, type checking, and Zig
   emission.
3. Implement V1 type and dynamic-feature rejection rules.
4. Add local modules and explicit standard-library wrappers after the core
   checker is stable.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Generated Zig artifact | Uses Zig as backend quickly | Direct machine code would slow the MVP and duplicate Zig/LLVM work |
