<!-- SPECKIT START -->
For additional context about technologies to be used, project structure, shell
commands, and other important information, read the current plan:
`specs/001-typescript-to-zig-native/plan.md`.

Active stack: Zig 0.16.0, Spec Kit, existing `src/lumen_compiler.zig` prototype.
Active product goal: TypeScript syntax -> generated Zig -> native binary.
<!-- SPECKIT END -->

## Commit Conventions

Do NOT add `Co-Authored-By:` trailers (or any AI/assistant attribution) to commit
messages. Write plain commit messages with no co-author lines.

## Project Direction

This branch is no longer driven by Test262 or ECMAScript engine conformance.
Treat the old ljs runtime as implementation history and useful source material,
not as the product goal.

The product goal is a compiled TypeScript-syntax language:

```text
.ts source -> compiler -> generated Zig -> native executable
```

The generated Zig is an implementation artifact. User-facing docs, diagnostics,
examples, and standard library design should describe the TypeScript-syntax
language, not Zig internals.

## Current Compiler Seed

- `src/lumen_compiler.zig` is the existing prototype compiler.
- `src/lumen.zig` exposes the current `compile` command.
- Keep the compiler isolated from the legacy interpreter/runtime path.
- Evolve toward `parse -> AST -> type check -> emit Zig -> build native`.

## Language Guardrails

- Source files use `.ts`.
- TypeScript syntax is the source surface.
- V1 is statically checked and compiled.
- `int` and `i32` both work for 32-bit signed integers.
- Remove JavaScript dynamism: no prototypes, no `eval`, no CommonJS, no dynamic
  object shape mutation.
- No package manager or remote packages in V1.
- Standard-library APIs should be familiar and Node-like where specified, but
  not full Node compatibility.

## Work Loop

Use Spec Kit for compiler milestones:

1. Update or create a focused spec folder.
2. Write plan/tasks before implementation.
3. Implement in small slices.
4. Verify with `zig build`, focused compiler examples, and any relevant tests.
5. Keep implementation docs aligned with the active TypeScript-to-native goal.

Do not reintroduce Test262 as a gate for the new compiler track.
