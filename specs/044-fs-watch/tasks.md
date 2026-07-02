# Tasks: fs.watch

## Phase 1

- [x] T1 `fs.watch(path, listener)` -- checker branch in `fsCallType`
  (`(string, (string) => void) -> void`, via `makeFuncType`/
  `ensureAssignable` matching `EventEmitter.on`'s listener validation).
- [x] T2 Runtime `__fsWatch`: `inotify_init1` + `inotify_add_watch` on
  `path` (create/modify/delete/move mask), then a blocking loop:
  `std.posix.read` the inotify fd, walk the returned `inotify_event`
  records (`getName()` for the changed filename, falling back to the
  watched path itself if the event has no name), call `listener` per
  event. Comptime-guarded to Linux only, matching `os.*`.
- [x] T3 Verified with a real directory and real filesystem operations
  (not simulated): started the watcher on `/tmp/watchdir` in the
  background, then from another process created a file (`echo >`),
  appended to it (`echo >>`), and deleted it (`rm`). The listener fired
  once per operation with the correct filename every time, in order, no
  crashes.
- [x] T4 Confirmed `--wasm` compiles and exits immediately at startup
  (exit code 1) via wasmtime, matching `http.createServer`'s precedent
  exactly -- verified, not assumed.
- [x] T5 `zig build test` passes. `zig build conformance` run clean.
- [x] T6 Updated `website/stdlib.html`: added to the existing `fs`
  section.
- [x] T7 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `EventEmitter`-based `FSWatcher` (see
the design question in spec.md for why this doesn't fit), event-type
distinction (`rename` vs `change`), recursive directory watching,
`fs.watchFile`/`unwatchFile`, non-Linux platforms.
