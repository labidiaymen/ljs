# Spec 113 — fs sync-method completeness (Node host)

**Status:** In progress.
**Axis:** Node host runtime (not Test262). First cycle of the Node-API pivot (after the JIT epic
banked its compute win). Goal: real scripts/CLIs — ljs's sweet spot (fast startup + native IO) —
should be able to do everyday file work, not just read/write/stat/readdir/mkdir.

## Why
`fs` today has `readFileSync`/`existsSync`/`writeFileSync`/`statSync`/`readdirSync`/`mkdirSync` — but
the everyday *mutating* ops are missing, so common scripts (build tools, generators, CLIs) fail on
`require('fs')` usage. These are the highest-traffic gaps and map directly to `std.Io.Dir` calls.

## In scope (this cycle) — sync methods
- `appendFileSync(path, data[, enc])` — append bytes (create if absent)
- `unlinkSync(path)` — delete a file (`Io.Dir.deleteFile`)
- `rmSync(path[, {recursive}])` — delete file or (recursive) tree (`deleteFile` / `deleteTree`)
- `rmdirSync(path)` — remove an empty directory (`deleteDir`)
- `renameSync(old, new)` — rename/move (`rename`)
- `copyFileSync(src, dest)` — copy a file (`copyFile`)
- `accessSync(path[, mode])` — throw if not accessible (`access`); existence check

## Out of scope (later cycles)
- Async callback API (`fs.readFile(path, cb)`) and `fs/promises` (`fs.promises.*`)
- `fs.constants`, file descriptors (`openSync`/`readSync`/`writeSync`/`closeSync`), `watch`,
  streams (`createReadStream`/`createWriteStream` — wait for a `stream` cycle), `chmod`/`utimes`/`symlink`.

## Success criteria
- Each method works on a real round-trip (write → append → read → copy → rename → unlink/rm → assert
  gone), verified by an in-engine script run with `ljs run`.
- Errors throw a Node-shaped error (`code` like `ENOENT`/`EACCES`) via the existing `fsError` helper.
- `zig build test` / `lint` / `bench` green; Test262 untouched (host-only layer, never on the engine path).
