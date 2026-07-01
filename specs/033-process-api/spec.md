# Feature Specification: process API

**Feature Branch**: `main` (milestone 033) | **Status**: Draft

**Input**: Crawl of <https://nodejs.org/docs/latest/api/process.html> (current
docs, fetched for this spec) against Lumen's stdlib. Lumen already has two
unnamespaced top-level functions, `argsCount()` and `arg(i)`, that cover a
sliver of `process.argv`. Node's `process` object exports dozens of
properties/methods, but the large majority are irrelevant to an
experiment-stage compiled language with no event loop introspection, no IPC,
no worker threads, and no signal handling yet (events, `report.*`,
`permission.*`, `finalization.*`, `dlopen`, `send`/`disconnect`, `hrtime`,
`memoryUsage`, `uid`/`gid` family, ...). This spec scopes a small,
high-value Phase 1: the subset every real program reaches for first (cwd,
exit, env, platform/arch, argv, pid).

## Scope

Unlike `fs` (every call threads `io`) and `path` (no call threads anything),
`process` is mixed: `cwd`/`chdir`/`env` go through `std.process`'s own `Io`-
abstracted primitives (so they take `io`, like `fs`), while `platform`/`arch`
are compile-time constants and `pid`/`argv` are cheap reads of state Zig's
own program entry already captured (no `Io` involved at all, like
`argsCount()`/`arg(i)` already work today).

### Phase 1 (this milestone)

| Function | Signature | Zig primitive |
| --- | --- | --- |
| `process.cwd()` | `() -> string` | `std.process.currentPath(io, buf)` -- a real, working `Io`-abstracted primitive (NOT the libc-only `realpath` gap that blocks `fs.realpathSync`; this is a different, already-implemented function) |
| `process.chdir(directory)` | `string -> void` | `std.process.setCurrentPath(io, path)` |
| `process.exit(code)` | `int -> void` | `std.process.exit(@intCast(code))`; truncates to `u8`, matching the rest of the stdlib's truncate-and-document posture (e.g. `fs.statSync`'s 32-bit size) |
| `process.env(key)` | `string -> string \| null` | `Environ.getPosix(environ, key)`; an already-established deviation (Node's `process.env` is a plain object with bracket access, Lumen has no dynamic-object indexing, so this is a function call instead -- this exact deviation was already documented in the stdlib Planned table before this spec existed) |
| `process.platform()` | `() -> string` | compile-time `@import("builtin").os.tag`, mapped to Node's naming (`"linux"`, `"macos"` -> `"darwin"`, ...) |
| `process.arch()` | `() -> string` | compile-time `@import("builtin").cpu.arch`, mapped to Node's naming (`"x86_64"` -> `"x64"`, `"aarch64"` -> `"arm64"`, ...) |
| `process.pid()` | `() -> int` | `std.os.linux.getpid()` -- a raw syscall, no libc link needed; Linux-specific, consistent with Lumen's existing POSIX-only (no Windows) posture |
| `process.argv()` | `() -> string[]` | returns the existing `__args` slice directly -- already collected at program start for `argsCount()`/`arg(i)`, zero new collection work and zero growable-array involvement (the same kind of "actually already free" discovery as `fs.readdirSync`'s two-pass fill) |

After Phase 1, `argsCount()`/`arg(i)` remain as-is (unnamespaced, pre-existing)
and `process.argv()` is purely additive -- the same underlying `__args` data,
indexed differently.

**Deviation from Node, confirmed by running it**: `process.argv()` follows
C/POSIX argv convention (index 0 is the invoked binary itself, then user
arguments follow), the same convention `arg(i)`/`argsCount()` already use --
not Node's convention, where `argv[0]` is the node executable and `argv[1]`
is the script path, so a user's first real argument is `argv[2]`. This isn't
a new deviation introduced here; `process.argv()` just inherits the
convention `arg(i)` already established.

**`process.platform()`/`process.arch()` are called as functions, not read as
properties** -- the same deviation already established for `path.sep()`/
`path.delimiter()` in spec 032: Lumen has no static-namespace constant-
property mechanism yet, only call dispatch.

**No `-lc` linking required for any Phase 1 function.** `currentPath`/
`setCurrentPath` go through the existing `Io` vtable (same linkage posture as
every `fs.*Sync` function); `Environ` is populated from the process's own
`envp` at entry, the same mechanism Zig already uses for `argv`; `getpid` is
a raw Linux syscall. This was confirmed by reading `Io/Threaded.zig`'s actual
backend implementations (not just the public signatures) before scoping
this, the same diligence applied when `fs.chownSync` turned out to be an
unimplemented stub despite a clean-looking public signature.

### Phase 2 / Not planned (needs more groundwork or is out of scope)

| Function | Blocker / reason |
| --- | --- |
| `process.hrtime()`, `process.uptime()` | needs a recorded process-start timestamp; no high-resolution timer wiring yet |
| `process.memoryUsage()`, `process.resourceUsage()`, `process.cpuUsage()`, `process.threadCpuUsage()` | low value for an experiment-stage language; revisit if requested |
| `process.kill()`, signal events (`SIGINT`, ...), `process.on(...)` | no event/listener infrastructure yet (same gap as `fs.watch`) |
| `process.send()`, `.disconnect()`, `.channel`, `.connected` (IPC) | Lumen has no child-process spawning yet, so no IPC channel can exist |
| `process.report.*`, `process.permission.*`, `process.finalization.*` | advanced/niche Node-internals surface, out of scope |
| `process.getuid/getgid/setuid/setgid/...` family | POSIX-only, niche for an experiment-stage language; revisit only if requested (same posture as the dropped `fs.chownSync`) |
| `process.version`, `process.versions`, `process.release`, `process.config`, `process.features.*` | Node-specific build metadata; not meaningful for Lumen |
| `process.stdout`/`stdin`/`stderr` (Stream objects) | no `Stream` abstraction in the language (same gap as `fs.createReadStream`) |
| `process.dlopen`, `.execve`, `.abort`, `.umask`, `.title`, `.execPath`, `.argv0`, `.mainModule` | niche/process-replacement-level operations, low value right now |

## Requirements

- **FR-001**: Each Phase 1 function follows the established stdlib pattern: a
  `lumen_check_stdlib.zig` `processCallType` branch (mirrors `fsCallType`/
  `pathCallType`), a `lumen_emit.zig` codegen branch, and a runtime helper in
  the `lumen_compiler.zig` prologue gated by `program.needs_process_api`.
  `"process"` is added to the parser's `isStdNamespace` list, the same gate
  `"path"` was added to in spec 032.
- **FR-002**: `process.cwd()`/`process.chdir()` set `program.uses_io = true`
  (they take `io`); `platform()`/`arch()`/`pid()`/`argv()` do not need `io`
  but still go through the same `program.uses_io`-gates-`__alloc`-declaration
  mechanism `path.*` already established, since `cwd()` and `env()` in the
  same namespace need it.
- **FR-003**: Failures swallow to a safe default (`""` for `cwd()` on error,
  silent no-op for `chdir()` on error), consistent with the rest of the
  stdlib's no-exceptions-yet posture.
- **FR-004**: Existing stdlib namespaces and all other language features MUST
  be unaffected (regression-checked via `zig build test` +
  `zig build conformance`).

## Success criteria

- **SC-001**: A program exercising all 8 Phase 1 functions together compiles
  and produces output cross-checked against `node -e` for the equivalent
  calls (`platform`/`arch`/`pid`/`cwd` values will differ by host, but the
  function shapes and `env`/`argv`/`chdir`/`exit` behavior are verified
  directly).
- **SC-002**: `zig build test` and `zig build conformance` are unaffected.

## Notes

`process.cwd()` shipping is also notable for the rest of the stdlib: spec 032
documented that `path.resolve()` cannot anchor a fully-relative input to the
real working directory because "there is no working `Io.Dir.realpath`/cwd
accessor". That was true for `fs`/`path` reaching for it directly, but
`std.process.currentPath` *is* exactly that accessor -- it was simply found
under `std.process`, not `std.Io.Dir`, while scoping this spec. A future
milestone could revisit `path.resolve`/`path.relative`/`fs.realpathSync`
using `process.cwd()` as the missing anchor. Not done in this milestone to
keep this spec's diff scoped to `process` itself, and because `path.resolve`
already shipped and is conformance-tested with its current, documented
behavior -- changing it is a deliberate follow-up, not a side effect of
adding `process.cwd()`.
