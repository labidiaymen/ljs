# Implementation Plan: TypeScript Syntax To Generated Zig Native Binary

**Branch**: `001-typescript-to-zig-native` | **Date**: 2026-06-25 |
**Spec**: [spec.md](./spec.md)

## Summary

Pivot the branch from JavaScript engine conformance to a native compiler product:
`.ts` source is parsed, statically checked, lowered to generated Zig, and compiled
to a native executable. The existing `src/tjsc.zig` prototype remains the
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
├── main.zig      # CLI, currently exposes compile command
└── tjsc.zig      # current compiler prototype, to evolve toward AST/checker/codegen

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
path.

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
