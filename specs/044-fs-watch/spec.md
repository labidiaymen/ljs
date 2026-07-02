# Spec 044: fs.watch

## Goal

`fs.watch(path, listener)`, the first `fs` addition explicitly deferred
earlier specifically on "no event/listener infrastructure yet" (spec
031's Not-planned table) -- `EventEmitter<T>` (spec 043) resolved that,
so this revisits it. Uses Linux's `inotify` directly
(`std.os.linux.inotify_init1`/`inotify_add_watch`), the same "raw syscall,
no libc" pattern already proven for `os.uptime()`/`uname()`.

## A design question resolved before writing code

Node's real `fs.watch()` returns an `FSWatcher`, which *is* an
`EventEmitter` (`watcher.on('change', cb)`). Given `EventEmitter<T>` now
exists, that looked like the obvious shape to copy -- but it doesn't
actually fit: nothing *drives* an emitter asynchronously on its own.
`.emit()` is a plain, synchronous method call; something still has to sit
in a loop reading `inotify` events and calling `.emit()` for each one. In
Node, libuv's event loop does that driving in the background while the
rest of the program keeps running. Lumen has no equivalent background
mechanism -- the async event loop that timers/`fs.readFile`/etc. use
still requires the program to be inside an `async`/`await` context to
keep spinning.

Given that, `fs.watch` here is a **blocking function**, the same shape as
`http.createServer`: it loops on `inotify` events forever, calling
`listener` synchronously per event, and never returns. Not `EventEmitter`-
based. A real, deliberate deviation from Node's actual class shape, not an
oversight -- documented here rather than forcing a shape that doesn't fit
the primitives available.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `fs.watch(path, listener)` | `(string, (string) -> void) -> void` | blocking; calls `listener` with the name of the file that changed on every create/modify/delete/rename event under `path`, forever |

Node's real callback takes two arguments, `(eventType, filename)`
(`eventType` is `"rename"` or `"change"`). This ships with one: just the
filename, matching the single-payload-argument shape every other
callback-taking builtin this session uses (`setInterval`,
`EventEmitter.on`, `child_process` has none but follows the same
one-concept-per-callback spirit). The specific create/modify/delete/rename
distinction is dropped for v1 -- "something changed, here's what" covers
the common "rebuild on any change" use case; splitting it out is a
straightforward follow-up if it turns out to matter.

## Design notes

- **Linux-only, comptime-guarded**: the same pattern `os.*`/
  `process.pid()` already established -- `if (builtin.os.tag == .linux)`
  around the actual `inotify` calls, so the struct/constant references
  stay safely referenceable everywhere (they're just data layouts) while
  the syscalls themselves are pruned from non-Linux targets.
- **wasm**: no listening-socket-equivalent capability under WASI for this
  either. Compiles cleanly, but exits immediately at startup (matching
  `http.createServer`'s exact precedent for the same reason: `inotify_init1`
  fails, there's no meaningful fallback for a function that's supposed to
  loop forever watching something), not a per-call degraded fallback like
  the client-style functions.
- **Watches one path, non-recursively**: matches `inotify_add_watch`'s own
  default (no `IN_ONLYDIR`/recursive flag set). Watching a directory
  reports changes to files directly inside it; watching a single file
  reports changes to that file. Recursive directory trees need watching
  each subdirectory individually -- not attempted here.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `EventEmitter`-based `FSWatcher` object, `.close()` to stop watching | doesn't fit without a background-driving mechanism; see the design question above |
| Distinguishing event types (`rename` vs `change`) | `inotify`'s mask already carries this; dropped from the callback for v1 simplicity, straightforward to add back |
| Recursive directory watching | needs watching every subdirectory individually, or the (less portable) `IN_ONLYDIR`-adjacent recursive support other platforms offer differently |
| `fs.watchFile`/`unwatchFile` (Node's older, polling-based API) | a different, poll-based mechanism than `inotify`; `fs.watch` covers the common case |
| Non-Linux platforms (macOS's `FSEvents`, `kqueue`; Windows' `ReadDirectoryChangesW`) | each a separate, real platform-specific primitive; only Linux implemented this pass, matching the `os` module's own Linux-first scope |
