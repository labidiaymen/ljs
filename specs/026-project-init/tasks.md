# Tasks: `lumen init`

- [x] T001 Enrich canonical `/lumen.d.ts` with an ambient `console` global
      (`log`/`error`).
- [x] T002 Wire `addAnonymousImport("lumen.d.ts", ...)` in `build.zig` so the
      root-level d.ts can be embedded from `src/lumen.zig`.
- [x] T003 Embed `lumen.d.ts` and define the generated `tsconfig.json`,
      `main.ts`, and `.gitignore` contents in `src/lumen.zig`.
- [x] T004 Implement `initProject` (dir create/open, per-file create-or-skip,
      summary + next-steps line).
- [x] T005 Add the `init` branch to the CLI dispatch and list `init` in both the
      no-args and shared usage text.
- [x] T006 `zig build` clean.
- [x] T007 Manual CLI verification: `lumen init [dir]`, compile + run the starter
      (`Hello, Lumen!`), re-run skip without clobber.
- [x] T008 `tsc --noEmit` on the fresh project -> 0 errors.
- [x] T009 `zig build conformance` -> 201 passed.
- [x] T010 Update README ("Getting started: `lumen init`") and website
      `#quickstart`.
