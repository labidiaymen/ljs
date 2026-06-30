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

After Phase 1 (+ `cpSync`, `mkdtempSync`, `statSync`), Lumen covers 19 of Node's 48 sync functions.

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
| `fs.realpathSync(path)`, `fs.utimesSync(path, atime, mtime)` | `realpath`/`utimes` only exist as raw `std.c` libc bindings in this Zig version, not wrapped by `std.Io.Dir`/`File`; calling them directly would bypass the `Io` abstraction every other fs function goes through (inconsistent, and breaks under wasm) |
| `fs.statfsSync(path)` | filesystem-level stats; platform-specific, low value for now |

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

### Not planned (needs a real language feature first)

| Group | Needs |
| --- | --- |
| `fs.lstatSync`, `fs.fstatSync` | `lstat` needs `Dir.statFile` to not follow symlinks (a flag away); `fstat` needs the fd-based group below. `statSync` itself **shipped** (see below) |
| `fs.readdirSync`, `fs.opendirSync`, `fs.globSync` | **growable arrays** (`Array.push` is not implemented yet — verified directly) or a directory-iterator class |
| `fs.openSync`/`closeSync`/`readSync`/`writeSync`/`readvSync`/`writevSync` and every `f*Sync` (`fchmodSync`, `fchownSync`, `fdatasyncSync`, `fstatSync`, `fsyncSync`, `ftruncateSync`, `futimesSync`) | a **file-descriptor** concept exposed to user code, plus a **`Buffer`** type for the read/write data — a bigger "fd API" feature, own spec |
| `fs.chownSync`, `fs.fchownSync`, `fs.lchownSync` | uid/gid ownership: POSIX-only, niche for an experiment-stage language; revisit only if requested |
| `fs.lchmodSync`, `fs.lutimesSync` | symlink-targeted variants of already-niche/deferred ops |
| All async/callback functions (`fs.readFile`, `fs.writeFile`, ... ~50 of them) and `fs.promises.*` | fs is not wired to the libuv event loop yet (async/await today only drives timers/promises); a real "async fs" milestone |
| `fs.createReadStream`/`createWriteStream` | no `Stream` abstraction in the language |
| `fs.watch`/`watchFile`/`unwatchFile` | no watcher/listener infra |
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
