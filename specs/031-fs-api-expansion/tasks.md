# Tasks: fs API expansion (Phase 1)

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
