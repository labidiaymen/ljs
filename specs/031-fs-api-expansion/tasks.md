# Tasks: fs API expansion (Phase 1)

- [ ] T1 `fs.rmdirSync(path)` — checker + codegen + `__rmdirSync` helper (`Dir.deleteDir`).
- [ ] T2 `fs.rmSync(path, recursive?)` — `Dir.deleteFile`/`deleteTree`, default `recursive=false`.
- [ ] T3 `fs.truncateSync(path, len)` — `Dir.openFile` (write) + `File.setLength`.
- [ ] T4 `fs.linkSync(existingPath, newPath)` — `Dir.hardLink`.
- [ ] T5 `fs.symlinkSync(target, path)` — `Dir.symLink`.
- [ ] T6 `fs.readlinkSync(path)` — `Dir.readLink` into a buffer, dupe into the arena.
- [ ] T7 `fs.chmodSync(path, mode)` — `Dir.openFile` + `File.setPermissions(.fromMode(mode))`.
- [ ] T8 `fs.accessSync(path, mode?)` — `Dir.access` with `AccessOptions` from the POSIX bitmask.
- [ ] T9 Verify: one program exercises all 8 together; `zig build test` + regex
  differential unaffected.
- [ ] T10 Update `website/stdlib.html`: move the 8 from Planned to Available now.
