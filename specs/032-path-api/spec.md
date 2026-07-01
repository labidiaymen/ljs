# Feature Specification: path API

**Feature Branch**: `main` (milestone 032) | **Status**: Draft

**Input**: Crawl of <https://nodejs.org/docs/latest/api/path.html> (current
docs, fetched for this spec) against Lumen's stdlib (`fs` is the only
filesystem-adjacent namespace today; `path` does not exist yet). Node's
top-level `path` module exports 13 functions plus 2 string constants
(`sep`, `delimiter`) and 2 platform sub-namespaces (`path.posix`,
`path.win32`). This spec inventories all of it, picks a Phase 1 batch
buildable today with existing language features and Zig's `std.fs.path`
(a pure string-manipulation module, no `std.Io`/syscalls involved at all),
and records why the rest is deferred.

## Scope

`path` is a natural companion to `fs` (paths are constructed before being
passed to `fs.*Sync` calls) and is considerably simpler to implement: every
Node `path.*` function is pure string logic with no filesystem access, so
nothing here needs `program.uses_io` or an `Io` parameter threaded through at
all -- a first for a Lumen stdlib namespace. Lumen targets POSIX only (no
Windows path emulation), matching the existing posture for `fs` (which never
implemented `fs.statfsSync`'s Windows variants either): `path.win32`,
`path.posix` (redundant when there is only one platform), and
`path.toNamespacedPath` (a Windows-only no-op on POSIX) are out of scope.

### Phase 1 (this milestone) — pure string ops, no new type machinery

| Function | Signature | Zig primitive |
| --- | --- | --- |
| `path.basename(path, suffix?)` | `(string, string?) -> string` | `std.fs.path.basename`, then strip `suffix` if given and present |
| `path.dirname(path)` | `string -> string` | `std.fs.path.dirname`, `""` on `null` (Node returns `"."` for a bare filename; see deviation) |
| `path.extname(path)` | `string -> string` | `std.fs.path.extension` |
| `path.isAbsolute(path)` | `string -> bool` | `std.fs.path.isAbsolute` |
| `path.normalize(path)` | `string -> string` | `std.fs.path.resolve(alloc, &.{path})` -- single-segment resolve collapses `.`/`..` without anchoring to an absolute root (see below) |
| `path.join(...paths)` | `(string, string, ...) -> string` (2-6 args) | `std.fs.path.join` (naive concat) piped through a single-segment `resolve` to collapse `.`/`..`, matching Node's `normalize(naiveJoin(...))` definition |
| `path.resolve(...paths)` | `(string, string, ...) -> string` (1-6 args) | `std.fs.path.resolve(alloc, paths)` -- "cd"-chains left to right, absolute segments reset the result; see deviation below |
| `path.parse(path)` | `string -> { root, dir, base, name, ext }` | `dirname`/`basename`/`extension`/`stem`, assembled into a second record-returning builtin (the same `__LumenStat`-style pattern from `fs.statSync`) |
| `path.format(parts)` | `{ dir?, base?, name?, ext? } -> string` | string concatenation mirroring Node's precedence (`dir`/`base` win over `root`/`name`+`ext` when both given) |
| `path.sep` | `string` (constant) | `"/"` (compile-time, since Lumen is POSIX-only) |
| `path.delimiter` | `string` (constant) | `":"` |

After Phase 1, Lumen covers 11 of Node's 13 `path` functions plus both
constants (everything except `relative` and `matchesGlob`, see below).

**Variadic `join`/`resolve` are scoped like `fs.cpSync`'s optional third
argument**: the checker validates a bounded arg count (2-6 for `join`, 1-6 for
`resolve`) directly, the same pattern already used for every fs function with
optional arguments. This sidesteps needing Lumen's user-facing rest-parameter
feature for a builtin -- the checker just unrolls a fixed range of arities,
exactly like `cpSync(src, dest, recursive?)` already does.

**Deviation from Node, `path.dirname`**: Node's `path.dirname("file.txt")`
(no separator) returns `"."` (current directory); Zig's
`std.fs.path.dirname` returns `null` for the same input. Lumen's
`path.dirname` returns `"."` for that `null` case specifically to match
Node's documented behavior, rather than surfacing the empty/null distinction.

**Deviation from Node, `path.resolve`**: Node's `path.resolve(...)` always
returns an absolute path -- if no argument is absolute, it implicitly
prepends `process.cwd()`. Zig's `std.fs.path.resolve` explicitly does *not*
do this (its doc comment: "will not convert relative paths to an absolute
path, use `Io.Dir.realpath` instead"), and Lumen has no working
`Io.Dir.realpath` to call (the same root gap already documented as blocking
`fs.realpathSync`). So `path.resolve("a", "b")` returns the normalized
relative path `"a/b"`, not an absolute path anchored at the real working
directory. This matches `path.resolve` exactly whenever at least one argument
is itself absolute (the common case), and is a documented, deliberate
deviation otherwise.

**`path.parse`/`path.format` are the second and third record-returning
builtins**, following the exact mechanism `fs.statSync` introduced: a
synthetic record type (`__LumenPathParts` for `parse`'s return value) is
lazily registered into `type_decls` the first time it is needed, with each
field's `checked_type` pre-set. `path.format` is the inverse direction (a
record *parameter* rather than return value) -- the checker validates the
argument against the same synthetic shape rather than registering a new one.

### Phase 2 / Not planned (needs more groundwork or a real language feature)

| Function | Blocker |
| --- | --- |
| `path.relative(from, to)` | needs the real OS working directory as a string to resolve relative `from`/`to` against (Zig's own `std.fs.path.relative` takes an explicit `cwd: []const u8` parameter -- there is no `Io.Dir.realpath`/`getCwd`-equivalent string accessor in this Zig version to supply it, the same root gap as `fs.realpathSync`) |
| `path.matchesGlob(path, pattern)` | needs a real glob algorithm (same blocker already documented for `fs.globSync`) |
| `path.win32`, `path.posix`, `path.toNamespacedPath` | Lumen targets POSIX only; no Windows path emulation planned |

## Requirements

- **FR-001**: Each Phase 1 function MUST follow the established stdlib
  pattern: a `lumen_check_stdlib.zig` branch (a new `pathCallType`, mirroring
  `fsCallType`) validating arg count/types, a `lumen_emit.zig` codegen branch,
  and a runtime helper in the `lumen_compiler.zig` prologue. Unlike every
  `fs.*` helper, none of these need `program.uses_io = true` or an `io`
  parameter -- pure string functions only need `__alloc`.
- **FR-002**: Failures are swallowed to a safe default (empty string),
  consistent with the rest of the stdlib's no-exceptions-yet posture.
- **FR-003**: Existing stdlib namespaces and all other language features MUST
  be unaffected (regression-checked via `zig build test` + the regex
  differential + `zig build conformance`).

## Success criteria

- **SC-001**: A program exercising all 11 Phase 1 functions together
  (basename, dirname, extname, isAbsolute, normalize, join, resolve, parse,
  format, sep, delimiter) compiles and produces the expected output, verified
  end to end against Node's actual output for the same inputs.
- **SC-002**: `zig build test`, the regex differential, and
  `zig build conformance` are unaffected.

## Notes

Verification here is hand-written example programs cross-checked against
`node -e`, the same approach used for `fs`. A future pass could promote the
most-used of these into a `specs/032-path-api/conformance` manifest once the
pattern is proven stable, matching how other milestones eventually graduate
into the conformance suite.
