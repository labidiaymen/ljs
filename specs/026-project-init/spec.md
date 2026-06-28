# Feature Specification: `lumen init` project scaffolder

**Feature Branch**: `main` (milestone 026) | **Status**: Draft

**Input**: Starting a Lumen project today means hand-writing the ambient type
declarations (`lumen.d.ts`) and a `tsconfig.json` before any editor or `tsc`
will type-check `.ts` sources without "cannot find name" noise. That is friction
the first time, and easy to get subtly wrong (e.g. pulling in the DOM lib, which
collides with Lumen's own `console`). `lumen init` removes that step: it
scaffolds a ready-to-edit project that is tsc/editor-clean from the first
keystroke.

## Scope

- A new `init` CLI action alongside `compile` and `test`.
- `lumen init` targets the current directory; `lumen init <dir>` targets/creates
  `<dir>`.
- Generates a fixed set of starter files (see below).
- Never overwrites an existing file: an existing target is skipped with a notice.
- Prints a summary of what was created/skipped and a next-steps line.

Out of scope: templates/flavors, dependency installation, git initialization,
any network access. V1 is a single fixed scaffold.

## Generated files

1. `lumen.d.ts` — the ambient declarations that make Lumen `.ts` sources
   type-check under plain tsc/editors. Sourced verbatim from the repo's
   canonical `/lumen.d.ts` (numeric/`bool` spellings, `Ref<T>`, and the runtime
   `console` global) via `@embedFile`, so it cannot drift from the editor
   experience.
2. `tsconfig.json` — minimal config that keeps the project tsc-clean: `target`
   and `lib` of `ESNext` (Math/Array, no DOM, so no duplicate `console`),
   `strict: false`, `noEmit: true`, `skipLibCheck: true`, `include: ["**/*.ts"]`.
3. `main.ts` — a small starter that both compiles+runs with `lumen` and
   type-checks under tsc: a typed `greet(name: string): string` using a template
   literal, plus a `console.log`.
4. `.gitignore` — ignores built binaries (`main`, `*.exe`) and the internal
   generated backend artifact (`.lumen-*.zig`).

## User Scenarios

### Scaffold and run (P1)

```sh
lumen init my-app
cd my-app
lumen compile main.ts && ./main      # prints: Hello, Lumen!
```

**Independent test**: `lumen init <dir>` then `lumen compile main.ts` and running
the binary prints the starter output; `tsc --noEmit` on the fresh project
reports zero errors.

### Re-run is non-destructive (P1)

Running `lumen init` again in a populated directory skips every file that already
exists (printing `skip <file> (exists)`) and leaves its contents untouched.

## Requirements

- **FR-001**: `lumen init` MUST scaffold into the current directory; `lumen init
  <dir>` MUST create (if needed) and scaffold into `<dir>`.
- **FR-002**: `init` MUST NOT overwrite an existing target file; it MUST skip it
  and print a notice naming the file.
- **FR-003**: The generated project MUST type-check under `tsc --noEmit` with
  zero errors using only the generated `lumen.d.ts` and `tsconfig.json`.
- **FR-004**: The generated `main.ts` MUST compile and run with `lumen compile`
  and print its starter output.
- **FR-005**: `lumen.d.ts` MUST be embedded from the canonical `/lumen.d.ts`
  (single source of truth), which MUST declare `console`.
- **FR-006**: `init` MUST print a summary (created/skipped counts) and a
  next-steps line (`lumen compile main.ts && ./main`).
- **FR-007**: The usage/help text MUST list `init`.

## Success Criteria

- **SC-001**: `lumen init <dir>` creates `lumen.d.ts`, `tsconfig.json`,
  `main.ts`, and `.gitignore`.
- **SC-002**: `tsc --noEmit` on the fresh project reports 0 errors.
- **SC-003**: `lumen compile main.ts` builds a binary that prints
  `Hello, Lumen!`.
- **SC-004**: Re-running `init` over an existing file skips it without changing
  its contents.
- **SC-005**: `zig build conformance` stays green (201 passed).

## TypeScript-validity note

The whole point of `init` is a project that is correct by construction for plain
TypeScript tooling: `ESNext`-only `lib` (no DOM) plus an ambient `console` means
no missing-name and no duplicate-`console` diagnostics. `lumen.d.ts` is shared
verbatim with the compiler's own editor-compatibility file.
