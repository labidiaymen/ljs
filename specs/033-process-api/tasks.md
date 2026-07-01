# Tasks: process API

## Phase 1

- [x] T1 Added `"process"` to the parser's `isStdNamespace` list. New
  `processCallType` in `lumen_check_stdlib.zig` (mirrors `fsCallType`/
  `pathCallType`), wired into `staticCallType`.
- [x] T2 `process.cwd()` — `std.process.currentPath(io, buf)`.
- [x] T3 `process.chdir(directory)` — `std.process.setCurrentPath(io, path)`.
- [x] T4 `process.exit(code)` — `std.process.exit(@intCast(code))`; verified
  the real shell exit code is set (42 in, 42 out) and nothing after the call
  executes.
- [x] T5 `process.env(key)` — `Environ.getPosix`, returns `string | null`.
- [x] T6 `process.platform()` — compile-time `builtin.os.tag`, Node naming.
- [x] T7 `process.arch()` — compile-time `builtin.cpu.arch`, Node naming.
- [x] T8 `process.pid()` — `std.os.linux.getpid()`.
- [x] T9 `process.argv()` — returns the existing `__args` slice directly;
  confirmed it follows C/POSIX argv convention (index 0 = the binary itself),
  the same convention `arg(i)` already used, not Node's node-then-script
  convention.
- [x] T10 Verify: one program exercises all 9 (platform, arch, pid, cwd,
  chdir, env found, env missing, argv length, argv contents) together;
  cross-checked against expected POSIX/host behavior — every value matched.
- [x] T11 `zig build test` passes. A final clean, non-concurrent
  `zig build conformance` run (fs Phase 3 + path + process all together)
  showed only the 5 known pre-existing failures, none new.
- [x] T12 Updated `website/stdlib.html`: new `process` quick-jump list + per
  function blocks (mirroring `fs`/`path`); updated Planned table.
- [x] T13 Commit, push. Redeploy `lumen-playground`: in progress.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Phase 2 / Not planned" table: `hrtime`/`uptime`,
`memoryUsage`/`resourceUsage`/`cpuUsage`, `kill`/signal events, IPC
(`send`/`disconnect`/`channel`), `report.*`/`permission.*`/`finalization.*`,
the `uid`/`gid` family, version/build metadata, `stdout`/`stdin`/`stderr`
streams, and misc niche operations (`dlopen`, `execve`, `abort`, `umask`,
`title`, `execPath`, `argv0`, `mainModule`).
