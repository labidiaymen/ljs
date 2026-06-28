# Implementation Plan: `lumen init`

## Stack

- Zig 0.16.0, existing `src/lumen.zig` CLI entry point.
- No new runtime dependencies; file I/O via `std.Io.Dir`.

## Design

### CLI dispatch (`src/lumen.zig`)

- Add an `init` branch to the `main` action dispatch, before `test`/`compile`,
  mirroring how those are matched with `std.mem.eql`.
- `lumen init` -> current dir; `lumen init <dir>` -> `<dir>` (created if absent).
- Reject more than one positional argument (print usage).
- Extend both the no-args usage line and the shared `usage` constant to list
  `lumen init [dir]`.

### Scaffolding (`initProject`)

- When a `dir` is given, `createDirPath` it, then `openDir`; otherwise operate on
  `cwd`.
- For each file in a fixed `init_files` table:
  - If `Dir.access` succeeds (file exists), print `skip <name> (exists)` and
    continue — never clobber.
  - Otherwise `Dir.writeFile` it and print `create <name>`.
- Print a one-line summary with created/skipped counts and a next-steps line.
  The next-steps line includes `cd <dir>` when a dir was given.

### File contents

- `lumen.d.ts`: `@embedFile("lumen.d.ts")`. The repo-root `/lumen.d.ts` is
  mapped into the module via `addAnonymousImport("lumen.d.ts", ...)` in
  `build.zig`, because a bare `@embedFile("../lumen.d.ts")` is rejected by Zig's
  package boundary. This keeps the canonical file the single source of truth.
- `tsconfig.json`, `main.ts`, `.gitignore`: inline multiline string literals.

### Canonical `lumen.d.ts`

- Add `declare const console: { log(...args: any[]): void; error(...args: any[]):
  void };` so a starter calling `console.log` type-checks without the DOM lib.

### Build wiring (`build.zig`)

- `exe.root_module.addAnonymousImport("lumen.d.ts", .{ .root_source_file =
  b.path("lumen.d.ts") })` so the embed resolves.

## Verification

- `zig build` clean.
- In a temp dir: `lumen init`, confirm the four files, `lumen compile main.ts`,
  run the binary -> `Hello, Lumen!`.
- `npx -p typescript tsc --noEmit` in the fresh project -> 0 errors.
- Re-run `init` in a populated dir -> skips without clobbering.
- `zig build conformance` -> 201 passed.

## Notes

A scaffolder is not a `.ts` compile-run case, so it gets no conformance manifest
entry; correctness is covered by the manual CLI + tsc verification above.
