# Tasks: os API

## Phase 1

- [x] T1 Added `"os"` to the parser's `isStdNamespace` list. New `osCallType`
  in `lumen_check_stdlib.zig` (mirrors `processCallType`), wired into
  `staticCallType`.
- [x] T2 `os.platform()` / `os.arch()` — same mapping as `process.*`.
- [x] T3 `os.type()` / `os.release()` / `os.version()` / `os.machine()` /
  `os.hostname()` — one shared `__osUname()` helper (`std.os.linux.uname`),
  each function just picks a different field via a comptime `@field`.
- [x] T4 `os.endianness()` — compile-time `builtin.cpu.arch.endian()`.
- [x] T5 `os.tmpdir()` — `TMPDIR`/`TMP`/`TEMP` env fallback `"/tmp"`.
- [x] T6 `os.homedir()` — `HOME` env var, `""` if unset (documented
  deviation: no passwd-lookup fallback, no libc dependency introduced).
- [x] T7 `os.uptime()` / `os.totalmem()` / `os.freemem()` / `os.loadavg()` —
  one shared `__osSysinfo()` helper (`std.os.linux.sysinfo`). Hit and fixed a
  real bug while wiring this up: Zig checks top-level declarations eagerly,
  not only when called, so `__osTmpdir`'s reference to `__processEnv` failed
  to compile for a program that used e.g. only `os.type()`. Fixed by having
  every `os.*` branch (not just `tmpdir`/`homedir`) set
  `program.needs_process_api = true`, guaranteeing `__processEnv`/`__environ`
  always exist alongside the unconditional `os.*` helper block.
- [x] T8 `os.availableParallelism()` — `std.Thread.getCpuCount()`.
- [x] T9 `os.EOL()` / `os.devNull()` — string constants.
- [x] T10 Verify: one program exercises all 17 together; cross-checked
  against `node -e` (platform/arch/type/machine/endianness/devNull matched
  exactly) / sanity-checked where host-dependent. Also caught and documented
  a real deviation while testing: `totalmem()`/`freemem()` truncate to
  32-bit `int`, so on this 12GB-RAM host `totalmem() > 0` was false (wraps
  negative) — fixed the test to check `!= 0` instead, matching the
  already-documented spec.md deviation.
- [x] T11 `zig build test` passes. `zig build conformance` run clean (no
  concurrent builds).
- [x] T12 Update `website/stdlib.html`: new `os` quick-jump list + per
  function blocks (mirroring `fs`/`path`/`process`); update Planned table.
- [x] T13 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Phase 2 / Not planned" table: `cpus()` (needs `/proc`
parsing into a record array), `networkInterfaces()` (needs interface
enumeration), `userInfo()` (needs a passwd lookup, same libc gap as
`homedir()`'s fallback), `getPriority`/`setPriority` (no wrapped Zig
primitive, would need a raw syscall number), `os.constants`.
