# Feature Specification: os API

**Feature Branch**: `main` (milestone 034) | **Status**: Draft

**Input**: Crawl of <https://nodejs.org/docs/latest/api/os.html> (current
docs, fetched for this spec) against Lumen's stdlib. Node's `os` module
exports around 20 functions/constants. Two (`platform`, `arch`) already
exist verbatim under `process.*` (spec 033); the rest split cleanly into "a
single syscall away" (uname, sysinfo) and "needs real groundwork" (per-core
CPU info, network interfaces, passwd lookups).

## Scope

Two syscalls cover almost this entire module:

- **`uname()`** (`std.os.linux.uname`, wrapped portably in
  `std.posix.gethostname` for the hostname case): one call fills `sysname`,
  `nodename`, `release`, `version`, `machine` -- covering `os.type()`,
  `os.hostname()`, `os.release()`, `os.version()`, `os.machine()` in one
  shot.
- **`sysinfo()`** (`std.os.linux.sysinfo`): one call fills `uptime`,
  `loads[3]`, `totalram`, `freeram` -- covering `os.uptime()`,
  `os.loadavg()`, `os.totalmem()`, `os.freemem()` in one shot.

Both are raw Linux syscalls with no libc dependency, the same posture as
every other raw-syscall primitive used in `process` (spec 033).

### Phase 1 (this milestone)

| Function | Signature | Zig primitive |
| --- | --- | --- |
| `os.platform()` | `() -> string` | same mapping as `process.platform()` |
| `os.arch()` | `() -> string` | same mapping as `process.arch()` |
| `os.type()` | `() -> string` | `uname().sysname` (e.g. `"Linux"`) |
| `os.release()` | `() -> string` | `uname().release` (kernel release string) |
| `os.version()` | `() -> string` | `uname().version` |
| `os.machine()` | `() -> string` | `uname().machine` (e.g. `"x86_64"`) |
| `os.hostname()` | `() -> string` | `uname().nodename` |
| `os.endianness()` | `() -> string` | compile-time `@import("builtin").cpu.arch.endian()` -> `"LE"`/`"BE"` |
| `os.tmpdir()` | `() -> string` | `TMPDIR`/`TMP`/`TEMP` env, falling back to `"/tmp"` -- Node's actual POSIX algorithm |
| `os.homedir()` | `() -> string` | `HOME` env var; `""` if unset (see deviation) |
| `os.uptime()` | `() -> int` | `sysinfo().uptime` |
| `os.totalmem()` | `() -> int` | `sysinfo().totalram * mem_unit` |
| `os.freemem()` | `() -> int` | `sysinfo().freeram * mem_unit` |
| `os.loadavg()` | `() -> number[]` | `sysinfo().loads[3]`, each divided by 65536.0 (Linux's fixed-point scale for load averages) |
| `os.availableParallelism()` | `() -> int` | `std.Thread.getCpuCount()` |
| `os.EOL()` | `() -> string` | `"\n"` (Lumen is POSIX-only) |
| `os.devNull()` | `() -> string` | `"/dev/null"` |

All are called as zero-arg functions, not read as properties (the same
deviation already established for `path.sep()`/`process.platform()`).
`os.platform()`/`os.arch()` are intentionally duplicated rather than shared
with `process.*` at the language level -- Node itself defines them
independently on both objects with identical values, so this matches Node's
actual shape rather than being a Lumen simplification.

**Deviation from Node, `os.homedir()`**: Node falls back to a passwd-database
lookup (`getpwuid`) when `HOME` is unset. That requires libc (no raw-syscall
passwd lookup exists), which no other stdlib function needs yet. Lumen
returns `""` when `HOME` is unset rather than introduce the first libc
dependency in the whole compiler for one fallback path -- `HOME` is set in
virtually every real POSIX environment.

**`os.totalmem()`/`os.freemem()` truncate to Lumen's 32-bit `int`**, the same
tradeoff already documented for `fs.statSync`'s `size` field -- a system with
more than ~2GB of RAM (i.e. almost all of them) will see a wrapped/truncated
value. Flagged here explicitly rather than silently wrong; a future 64-bit
integer type would fix this properly.

### Phase 2 / Not planned (needs more groundwork or is out of scope)

| Function | Blocker |
| --- | --- |
| `os.cpus()` | needs a record array (one record per core: `model`, `speed`, `times{user,nice,sys,idle,irq}`) parsed from `/proc/cpuinfo`/`/proc/stat`; real work, no single syscall shortcut |
| `os.networkInterfaces()` | needs `getifaddrs`-equivalent enumeration (`NETLINK` sockets on Linux without libc); real work |
| `os.userInfo()` | needs a passwd-database lookup (`getpwuid`), the same libc gap as `os.homedir()`'s fallback, for `username`/`shell` specifically (uid/gid/homedir are otherwise available) |
| `os.getPriority()`/`os.setPriority()` | `getpriority`/`setpriority` have no wrapped primitive in this Zig version (would need a raw `std.os.linux.syscall2(.getpriority, ...)`, less vetted than every other primitive used so far); low value, revisit if requested |
| `os.constants` | a large constants object (signals, errno, priority levels); low value without the functions that consume them (`setPriority`, signal handling) |

## Requirements

- **FR-001**: Each Phase 1 function follows the established pattern: a
  `lumen_check_stdlib.zig` `osCallType` branch (mirrors `processCallType`), a
  `lumen_emit.zig` codegen branch, and runtime helpers in
  `lumen_compiler.zig` gated by `program.needs_os_api`. `"os"` is added to
  the parser's `isStdNamespace` list.
- **FR-002**: No `-lc` linking required for any Phase 1 function (raw Linux
  syscalls only, same posture as `process`).
- **FR-003**: Failures swallow to a safe default (`""` for strings, `0` for
  numbers), consistent with the rest of the stdlib.
- **FR-004**: Existing stdlib namespaces and all other language features MUST
  be unaffected (regression-checked via `zig build test` +
  `zig build conformance`).

## Success criteria

- **SC-001**: A program exercising all 17 Phase 1 functions together compiles
  and produces output cross-checked against `node -e` where host-independent
  (`endianness`, `EOL`, `devNull`, `tmpdir` fallback behavior, `platform`,
  `arch`, `type`) and sanity-checked where host-dependent (`hostname`,
  `uptime` > 0, `totalmem`/`freemem` > 0, `availableParallelism` > 0).
- **SC-002**: `zig build test` and `zig build conformance` are unaffected.

## Notes

`os.loadavg()` is the first stdlib function returning `number[]` (a `f64`
array) rather than `string[]`/`int` -- confirmed the same "already a plain
slice, not growable" property holds for `f64_array` as it did for
`string_array` (`fs.readdirSync`) before relying on it; the array is always
exactly 3 elements, allocated directly with no two-pass counting needed.
