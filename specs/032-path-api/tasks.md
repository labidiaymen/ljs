# Tasks: path API

## Phase 1

- [x] T1 New `pathCallType` in `lumen_check_stdlib.zig` (mirrors `fsCallType`),
  wired into the checker's static-call dispatch the same way `fs`/`Math`/
  `String`/`Promise` are. Also added `"path"` to the parser's
  `isStdNamespace` list (the same gate that recognizes `fs`/`Math`/etc as a
  static-call namespace at parse time).
- [x] T2 `path.basename(path, suffix?)` — `std.fs.path.basename`, strip
  `suffix` if given and present.
- [x] T3 `path.dirname(path)` — `std.fs.path.dirname`, `"."` on `null`
  (deviation from Zig's `null`, matches Node).
- [x] T4 `path.extname(path)` — `std.fs.path.extension`.
- [x] T5 `path.isAbsolute(path)` — `std.fs.path.isAbsolute`.
- [x] T6 `path.normalize(path)` — single-segment `std.fs.path.resolve`.
- [x] T7 `path.join(...paths)` (2-6 args) — naive `std.fs.path.join` piped
  through a single-segment `resolve` to collapse `.`/`..`.
- [x] T8 `path.resolve(...paths)` (1-6 args) — `std.fs.path.resolve`; document
  the no-real-cwd-anchor deviation inline where it's emitted.
- [x] T9 `path.parse(path)` — registers `__LumenPathParts` record type
  (`root`, `dir`, `base`, `name`, `ext`), assembled from
  `dirname`/`basename`/`extension`.
- [x] T10 `path.format(parts)` — record-typed parameter (all 5 fields
  required, a documented deviation from Node's optional fields), Node's
  dir/base-over-root/name+ext precedence.
- [x] T11 `path.sep()` / `path.delimiter()` — zero-arg functions, not
  properties (deviation: no static-namespace constant-property mechanism
  exists yet).
- [x] T12 Verify: one program exercises all 11 together; output cross-checked
  against `node -e` for the same inputs — all 20 checks matched exactly.
- [x] T13 `zig build test` passes. `zig build conformance` run alongside the
  Phase 3 fs batch (see `specs/031-fs-api-expansion/tasks.md`); no new
  failures from either body of work.
- [x] T14 Updated `website/stdlib.html`: new `path` quick-jump list + per
  function blocks (mirroring the `fs` section); moved `path.*` out of the
  Planned table (`relative`/`matchesGlob`/win32 variants remain, correctly).
- [x] T15 Commit, push. Redeploy `lumen-playground`: in progress.

## Phase 2 / deferred (tracked, not scheduled)

- `path.relative(from, to)` — blocked on no real-cwd-as-string primitive
  (same root gap as `fs.realpathSync`).
- `path.matchesGlob` — blocked on no glob algorithm (same as `fs.globSync`).
- `path.win32` / `path.posix` / `path.toNamespacedPath` — out of scope,
  POSIX-only target.
