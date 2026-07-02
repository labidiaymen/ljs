# Feature Specification: fs API expansion

**Feature Branch**: `main` (milestone 031) | **Status**: Draft

**Input**: Crawl of <https://nodejs.org/docs/latest/api/fs.html> (current docs,
fetched for this spec) against Lumen's existing `fs` surface
(`src/lumen_check.zig` `fsCallType`, `src/lumen_emit.zig`, prologue helpers in
`src/lumen_compiler.zig`). Node's top-level `fs` module exports **48 `*Sync`
functions** and 54 async/callback functions. Lumen has 8 of the sync ones
(`readFileSync`, `writeFileSync`, `appendFileSync`, `existsSync`, `mkdirSync`,
`unlinkSync`, `renameSync`, `copyFileSync`). This spec inventories the rest,
picks a Phase 1 batch that is buildable today with existing language features,
and records why everything else is deferred.

## Scope

Lumen is statically typed with no dynamic `Buffer`/fd-handle/record-builtin
machinery yet, and `fs` calls only run synchronously (no event loop wiring for
fs). So scope is bounded by what the *language* can express today, not just
what `std.Io.Dir` in Zig can do.

### Phase 1 (this milestone) — path-based, scalar in/out, no new type machinery

| Function | Signature | Zig primitive |
| --- | --- | --- |
| `fs.rmdirSync(path)` | `string -> void` | `Dir.deleteDir` |
| `fs.rmSync(path, recursive?)` | `(string, bool?) -> void` | `Dir.deleteFile` / `Dir.deleteTree` |
| `fs.truncateSync(path, len)` | `(string, int) -> void` | `Dir.openFile` (write) + `File.setLength` |
| `fs.linkSync(existingPath, newPath)` | `(string, string) -> void` | `Dir.hardLink` |
| `fs.symlinkSync(target, path)` | `(string, string) -> void` | `Dir.symLink` |
| `fs.readlinkSync(path)` | `string -> string` | `Dir.readLink` |
| `fs.chmodSync(path, mode)` | `(string, int) -> void` | `Dir.openFile` + `File.setPermissions(.fromMode(mode))` |
| `fs.accessSync(path, mode?)` | `(string, int?) -> bool` | `Dir.access` with `AccessOptions{read,write,execute}` |
| `fs.cpSync(src, dest, recursive?)` | `(string, string, bool?) -> void` | `Dir.openDir(.{.iterate=true})` + `Dir.iterate`, recursing; falls back to a single `copyFile` |
| `fs.mkdtempSync(prefix)` | `string -> string` | `Dir.createDir` with a timestamp+counter suffix (not cryptographic) |
| `fs.statSync(path)` | `string -> { size, isFile, isDirectory, mtimeMs }` | `Dir.statFile`; the first **record-returning builtin** (see below) |
| `fs.openSync(path, flags)` | `(string, string) -> int` | `Dir.openFile`/`createFile`; `flags` is `"r"` or `"w"` only (no `"a"`, see Phase 2) |
| `fs.closeSync(fd)` | `int -> void` | `File.close` |
| `fs.readSync(fd, length)` | `(int, int) -> string` | `File.readStreaming` |
| `fs.writeSync(fd, data)` | `(int, string) -> int` | `File.writeStreamingAll`, returns `data.len` |

After Phase 1 (+ `cpSync`, `mkdtempSync`, `statSync`, the fd group) and Phase 3
(12 more: `lstatSync`, `fstatSync`, `fchmodSync`, `lchmodSync`, `fchownSync`,
`fsyncSync`, `fdatasyncSync`, `ftruncateSync`, `futimesSync`, `utimesSync`,
`lutimesSync`, `readdirSync`), Lumen covers 35 of Node's 48 sync functions.

**The fd group is a deliberately scoped version of Node's fd API**, unblocked
by treating a "fd" as a plain `int` (an index into an internal
`std.Io.File` table) rather than a real OS handle, and using `string` instead
of a `Buffer` for read/write data (Lumen has no `Buffer` type). This keeps the
group inside the existing language surface instead of waiting on two more
features. Deviations from Node: `openSync` only supports `"r"`/`"w"` flags (no
`"a"`/append — no seek primitive in this Zig version's `std.Io.File`);
`writeSync` always writes the full string and returns its length rather than a
possibly-partial byte count.

**`statSync` is the proof-of-concept for record-returning builtins.** Lumen
had no mechanism for a builtin to return a multi-field object before this: the
checker lazily registers a synthetic record type (`__LumenStat`) into the same
`type_decls` map a user `type X = {...}` declaration would use, with each
field's `checked_type` pre-set (skipping annotation resolution, which expects
source text). Everything downstream — field access (`s.size`), the
declaration's emitted Zig type (`types.zigName` on a `.named` type returns the
name verbatim) — is the *existing* record machinery, unmodified. Deviation
from Node: `isFile`/`isDirectory` are plain `bool` **fields**, not methods (no
method dispatch on a builtin-record type yet); `size`/`mtimeMs` are Lumen's
32-bit `int`, truncating for files >2GB or dates needing >32-bit millisecond
precision (an experiment-stage tradeoff, not Node-exact).

**Deviation from Node, called out explicitly**: Node's `accessSync` *throws* on
failure and returns nothing; Lumen's returns `bool` (like `existsSync`) for
consistency with the rest of the bool-returning fs surface and to avoid a
detour into exception-based builtins. `mode` is the POSIX bitmask
(`R_OK=4, W_OK=2, X_OK=1`); omitted means existence-only (`F_OK`).

### Phase 2 (future, needs more groundwork but no new language feature)

| Function | Blocker |
| --- | --- |
| `fs.mkdtempDisposableSync` | the `using`-disposable variant; `mkdtempSync` itself shipped (see below) |
| `fs.statfsSync(path)` | filesystem-level stats; platform-specific, low value for now |
| append-mode `fs.openSync(path, "a")` | no `seek`/`lseek` exposed on `std.Io.File` in this Zig version |

### Phase 3 — unblocked by re-checking the actual `std.Io` API surface

An earlier pass under-searched `std.Io.Dir`/`File` (wrong function names: looked
for `updateTimes`, not the real `setTimestamps`) and marked several functions
"needs a new language feature" that turned out to need neither — just a
primitive that was there all along, or a reframing that avoids the missing
feature entirely:

| Function | How it's actually achievable |
| --- | --- |
| `fs.lstatSync(path)` | `Dir.statFile(io, path, .{.follow_symlinks = false})`, reuses `__LumenStat` |
| `fs.fstatSync(fd)` | `__fd_table[fd].stat(io)`, reuses `__LumenStat` |
| `fs.fchmodSync(fd, mode)` | `__fd_table[fd].setPermissions(io, .fromMode(mode))` |
| `fs.fchownSync(fd, uid, gid)` | `File.setOwner` -- the fd-based POSIX `fchown` syscall, fully implemented in this Zig version's `Io.Threaded` backend |
| `fs.fsyncSync(fd)`, `fs.fdatasyncSync(fd)` | `File.sync`; `fdatasyncSync` aliases it (Zig does not distinguish data-only sync) |
| `fs.ftruncateSync(fd, len)` | `File.setLength` (already used by the path-based `truncateSync`) |
| `fs.futimesSync(fd, atimeMs, mtimeMs)`, `fs.utimesSync(path, ...)`, `fs.lutimesSync(path, ...)` | `File.setTimestamps` / `Dir.setTimestamps(..., .{.follow_symlinks})` -- **`Dir.setTimestamps` exists**; the earlier "blocked" call was wrong |
| `fs.lchmodSync(path, mode)` | `Dir.openFile(.{.follow_symlinks = false})` + `File.setPermissions`; best-effort (POSIX itself does not let every OS chmod a symlink) |
| `fs.readdirSync(path) -> string[]` | **routes around the growable-array blocker entirely**: `string[]` already lowers to a plain `[]const []const u8` (checked in `lumen_types.zig`), not a growable buffer, so a two-pass `Dir.iterate()` (count, then allocate-and-fill) produces one with no `Array.push` involved |

**`fs.chownSync(path, uid, gid)` / `fs.lchownSync(path, uid, gid)` turned out to
still be blocked**, despite `Dir.setFileOwner` existing as a *declared*
function: this Zig version's default `Io.Threaded` backend has it as an
unconditional `@panic("TODO implement dirSetFileOwner")` on Linux (verified by
reading `Io/Threaded.zig` directly), and even setting that aside, `Dir.zig`'s
own `setFileOwner` wrapper has a real signature bug -- its declared return
type (`SetOwnerError!void`) doesn't include `error.NameTooLong` /
`error.BadPathName`, which the vtable call it wraps can actually produce, so
it fails to even type-check. The fd-based `fs.fchownSync` does NOT share this
problem (`File.setOwner` is a real, working `fchown` syscall wrapper) and
shipped normally.

After Phase 3, Lumen will cover essentially all of Node's *synchronous,
path/fd-based* fs surface -- everything except `realpathSync` (raw-libc-only),
append-mode `openSync`, `statfsSync`, `chownSync`/`lchownSync` (stdlib stub,
see above), and `globSync`/`opendirSync` (need a real glob algorithm /
directory-iterator class, not just an array).

### Phase 5 -- revisited again (2026-07-02): `realpathSync`, `chownSync`, `writevSync`

Re-checked three more "blocked" entries rather than continuing to trust the
earlier notes, the same way Phase 3 re-checked "needs a new language feature"
and found several were wrong:

| Function | What was actually true |
| --- | --- |
| `fs.realpathSync(path)` | The "only a raw libc binding" note was stale. This Zig version's `std.Io.Dir` has a real `realPathFileAlloc`, dispatching to a genuine per-OS implementation (confirmed by reading `Io/Threaded.zig`'s `dirRealPathFile`, not a stub). Shipped; falls back to returning `path` unchanged on error. Verified against a real symlink, not just a plain file. |
| `fs.chownSync(path, uid, gid)` | Still true that path-based `Dir.setFileOwner` panics unconditionally. But `File.setOwner` (the fd-based one `fchownSync` already uses) is a real, working implementation -- so this opens the file first (the same "open, then use the file-level method" pattern `chmodSync` already established) and calls that instead, sidestepping the broken path-level wrapper entirely. Verified with a real ownership change confirmed via `stat` (running as root in the dev container). |
| `fs.writevSync(fd, buffers)` | `std.Io.File` genuinely has no vectored-write wrapper, but the raw `std.os.linux.writev` syscall exists -- the same "raw Linux syscall, no libc" pattern `os.uptime()`/`fs.watch` already established. Ran into one real bug while shipping this: `std.os.linux.iovec_const` is a private alias, not the type to actually reference -- `std.posix.iovec_const` is. Shipped; verified with a 3-chunk write reassembling correctly in one syscall. `readvSync` is deliberately not shipped alongside it: Node's `readv` fills caller-provided *mutable* buffers, and Lumen's `string` is immutable, so that signature has no natural Lumen shape the way `writevSync`'s (read-only chunks in, byte count out) does. |
| `fs.lchownSync(path, uid, gid)` | Still genuinely blocked, but for a more precise reason now: unlike `chownSync`, this one must *not* follow a symlink, and `std.Io.Dir.OpenFileOptions` has no "don't follow symlinks" field to open one without following it (confirmed by reading the struct directly) -- so there's no path-level handle to call `setOwner` on the way `chownSync` does. Would need a raw `fchownat(..., AT_SYMLINK_NOFOLLOW)` syscall instead, not attempted this pass. |

`fs.cpSync(src, dest, recursive?)` and `fs.mkdtempSync(prefix)` **shipped** (see
Available now).

- `cpSync` is composed from `Dir.openDir(.{.iterate=true})` + `Dir.iterate` + the
  existing `copyFileSync`/`mkdirSync` primitives, recursing into subdirectories
  when `recursive` is true (default false, matching `mkdirSync`'s convention) and
  falling back to a single file copy when the source does not open as a
  directory.
- `mkdtempSync` generates its unique suffix from `std.Io.Clock.now(.real,
  io).nanoseconds` mixed with a per-process counter, **not cryptographic
  randomness** (this Zig version has no clear `std.crypto.random` source) --
  adequate for a unique scratch directory name, not for anything
  security-sensitive. Returns the created path, or `""` on failure.

### Phase 4 -- true async I/O: `fs.readFile`, `fs.writeFile`, `fs.appendFile`

Three functions run on the async event loop instead of blocking:
`fs.readFile(path) -> Promise<string>`, `fs.writeFile(path, data) ->
Promise<void>`, and `fs.appendFile(path, data) -> Promise<void>`. All three are
genuinely non-blocking (no thread pool involved, unlike Node's own
`fs.promises.*`), reading or writing in a loop of fixed-size chunks until done,
then resolving the promise. `writeFile` and `appendFile` share one write loop;
`appendFile` differs only in where it starts writing -- one fast synchronous
stat call up front finds the file's current size, then the same async loop
writes starting there instead of at 0. That sidesteps needing a seek
primitive entirely (see the sync `openSync("a")` row below, which is a
genuinely different, still-blocked path).

Everything else in `fs` stays synchronous; the async trio above is additive,
not a replacement.

### Not planned (needs a real language feature first)

| Group | Needs |
| --- | --- |
| `fs.opendirSync`, `fs.globSync` | a directory-iterator class / a real glob algorithm — `readdirSync` itself **shipped** (Phase 3, two-pass array fill) |
| `fs.readvSync`, append-mode `openSync` ("a") | `readv` fills caller-provided mutable buffers, no natural Lumen shape given `string` is immutable (`writevSync` **shipped**, Phase 5); append mode needs a seek primitive not available here (unrelated to async `fs.appendFile`, which computes its start offset from a stat call instead of seeking) |
| `fs.statfsSync` | see Phase 2 blockers above |
| `fs.lchownSync` | needs a raw `fchownat(..., AT_SYMLINK_NOFOLLOW)` syscall — see Phase 5 (`chownSync` itself **shipped**) |
| Remaining async/callback functions (`fs.unlink`, `fs.mkdir`, `fs.stat`, ... most of the ~54) and `fs.promises.*` beyond `readFile`/`writeFile`/`appendFile` | the underlying async runtime only exposes read/write/close as true async ops (confirmed by reading its io_uring backend directly) -- no unlink/mkdir/stat op exists to build on without submitting raw low-level requests ourselves, a bigger undertaking than this milestone |
| `fs.watch`/`watchFile`/`unwatchFile` | no watcher/listener infra -- `fs.watch(path, listener)` itself **shipped** (spec 044) |
| `fs.openAsBlob` | no `Blob` type |

## Requirements

- **FR-001**: Each Phase 1 function MUST follow the established pattern: a
  `Program.needs_*` flag, a `lumen_check.zig` `fsCallType` branch validating
  arg count/types, a `lumen_emit.zig` codegen branch lowering to
  `__fnSync(__io, ...)`, and a flag-gated runtime helper in the
  `lumen_compiler.zig` prologue that wraps the `std.Io.Dir`/`File` primitive.
- **FR-002**: Failures are swallowed to a safe default (`void` functions catch
  and no-op; `accessSync` catches to `false`) — consistent with the existing
  `readFileSync`/`existsSync` behavior (no exceptions from fs builtins yet).
- **FR-003**: Existing fs functions and all other language features MUST be
  unaffected (regression-checked via `zig build test` + the regex differential
  + a manual smoke test per function).

## Success criteria

- **SC-001**: A program exercising all 8 Phase 1 functions together (create,
  link, symlink, readlink, chmod, access-check, truncate, rmdir/rm) compiles
  and produces the expected output, verified end to end.
- **SC-002**: `zig build test` and the regex differential suite are unaffected.

## Notes

Verification here is hand-written example programs (no `std.Io.Dir` mock
exists), the same approach already used for `readFileSync`/`existsSync`/etc.
A future pass could promote the most-used of these into a `specs/.../conformance`
manifest once the pattern is proven stable.
