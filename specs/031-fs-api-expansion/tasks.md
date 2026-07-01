# Tasks: fs API expansion

## Phase 1

- [x] T1 `fs.rmdirSync(path)` — checker + codegen + `__rmdirSync` helper (`Dir.deleteDir`).
- [x] T2 `fs.rmSync(path, recursive?)` — `Dir.deleteFile`/`deleteTree`, default `recursive=false`.
- [x] T3 `fs.truncateSync(path, len)` — `Dir.openFile` (write) + `File.setLength`.
- [x] T4 `fs.linkSync(existingPath, newPath)` — `Dir.hardLink`.
- [x] T5 `fs.symlinkSync(target, path)` — `Dir.symLink`.
- [x] T6 `fs.readlinkSync(path)` — `Dir.readLink` into a buffer, dupe into the arena.
- [x] T7 `fs.chmodSync(path, mode)` — `Dir.openFile` + `File.setPermissions(.fromMode(mode))`.
- [x] T8 `fs.accessSync(path, mode?)` — `Dir.access` with `AccessOptions` from the POSIX bitmask.
- [x] T9 Verify: one program exercises all 8 together; `zig build test` + regex
  differential unaffected.
- [x] T10 Update `website/stdlib.html`: move the 8 from Planned to Available now.

## Phase 3 (re-scoped: not actually blocked)

- [x] T11 `fs.lstatSync(path)` — `Dir.statFile(.{.follow_symlinks=false})`, reuses `__LumenStat`.
- [x] T12 `fs.fstatSync(fd)` — `__fd_table[fd].stat(io)`, reuses `__LumenStat`.
- [x] T13 `fs.fchmodSync(fd, mode)` — `__fd_table[fd].setPermissions(.fromMode(mode))`.
- [x] T14 `fs.fchownSync(fd, uid, gid)` — `__fd_table[fd].setOwner(io, uid, gid)`.
- [~] T15 `fs.chownSync(path, uid, gid)` / `fs.lchownSync(path, uid, gid)` — DROPPED:
  `Dir.setFileOwner` is an unimplemented stub (`@panic("TODO implement
  dirSetFileOwner")`) in this Zig version's `Io.Threaded` backend, plus a
  signature bug in the wrapper itself (declared error set doesn't match what
  it actually returns). Moved to spec.md's "Not planned" table.
- [x] T16 `fs.fsyncSync(fd)` / `fs.fdatasyncSync(fd)` — `__fd_table[fd].sync(io)` (fdatasync aliases fsync).
- [x] T17 `fs.ftruncateSync(fd, len)` — `__fd_table[fd].setLength(io, len)`.
- [x] T18 `fs.futimesSync(fd, atimeMs, mtimeMs)` — `__fd_table[fd].setTimestamps(io, ...)`.
- [x] T19 `fs.utimesSync(path, atimeMs, mtimeMs)` / `fs.lutimesSync(path, ...)` — `Dir.setTimestamps(..., .{.follow_symlinks})`.
- [x] T20 `fs.lchmodSync(path, mode)` — `Dir.openFile(.{.follow_symlinks=false})` + `File.setPermissions`.
- [x] T21 `fs.readdirSync(path) -> string[]` — two-pass `Dir.iterate()` (count, then allocate-exact + fill).
- [x] T22 Verify: one program exercises the whole Phase 3 batch; `zig build test` +
  `zig build conformance` unaffected (a clean, non-concurrent final run showed
  only the 5 known pre-existing failures, none new).
- [x] T23 Update `specs/031-fs-api-expansion/spec.md` coverage count and
  `website/stdlib.html` (quick-jump list + per-function blocks + Planned table).
- [x] T24 Commit, push. Redeploy `lumen-playground` Docker service: in progress.
