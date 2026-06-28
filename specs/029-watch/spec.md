# Feature Specification: `lumen watch` rebuild-on-change

**Feature Branch**: `main` (milestone 029) | **Status**: Draft

**Input**: The edit loop today is manual: change a `.ts` source, re-run
`lumen compile main.ts`, then run `./main` again. For an interactive workflow
that round trip is the dominant cost. `lumen watch` collapses it: it watches the
entry file and its local import closure, rebuilds whenever any of them changes,
and (by default) re-runs the freshly built binary, restarting the previous run.

## Scope

- A new `watch` CLI action alongside `compile`, `test`, and `init`.
- `lumen watch <file.ts>` rebuilds on change and auto-re-runs the binary.
- `lumen watch --no-run <file.ts>` rebuilds only (no execution).
- `--release-fast` / `--release-safe` select the build mode, matching `compile`
  (default `--release-safe`).
- The watched set is the entry file PLUS its transitive LOCAL import closure.
  `https://` URL imports are remote/build-time and are NOT watched.
- The watched set is recomputed on every rebuild so added/removed local imports
  are tracked.
- Ctrl-C (SIGINT) stops the watcher cleanly and kills the running child.

Out of scope: platform fs-event APIs, watching non-imported sibling files,
hot-reload/state preservation, multiple concurrent entry points, debounce
configuration.

## Behavior

1. On start, `watch` performs an initial build (and run, unless `--no-run`), then
   prints `watching N files (Ctrl-C to stop)`.
2. It polls the watched files every ~150 ms.
3. When any watched file's contents change, or a watched file appears/disappears,
   it rebuilds.
4. A successful rebuild reuses the exact `lumen compile` path, so the success
   line and any diagnostics are byte-for-byte identical to `lumen compile`.
5. On a successful rebuild with running enabled, the previously spawned child is
   killed and the freshly built binary is spawned (`./<stem>`), inheriting the
   terminal's stdio.
6. On a failed rebuild, the diagnostic is printed and the watcher reports
   `watch: build failed; keeping previous run` — the last good run (if any) keeps
   going and the watcher stays alive. Fixing the error rebuilds normally.
7. SIGINT kills the child and prints `watch: stopped`.

## Change-detection mechanism

Change detection is **content-based polling**: every poll the watcher reads each
watched file and compares a 64-bit content hash against the previous snapshot.

Polling (rather than platform fs-event APIs) is deliberate: Zig's standard
library has no portable file-system watcher, and polling a handful of files is
dependency-free and predictable.

Content hashing (rather than mtime) is required on this toolchain: under the
process I/O used by the CLI, the file-stat path returns a **stale modification
time** after a `zig build-exe` child has run, while file *reads* stay fresh. A
content hash of the file bytes is therefore the reliable change signal. The cost
is one read per watched file per poll, which is negligible for the small local
import closures Lumen programs have.

## Signal handling

On POSIX targets a `SIGINT`/`SIGTERM` handler is installed. The running child's
process id is published to a process-global atomic so the handler can terminate
it directly and set an `interrupted` flag the poll loop observes to exit cleanly.
On non-POSIX targets the handler is inert; the child is still killed between
rebuilds and on loop exit, so stopping the watcher still tears the child down.

## CLI usage

```text
lumen watch [--no-run] [--release-fast] <file.ts>
```

## Verification

Manual (a long-running watcher is not a compile-run conformance fixture):

- Editing the entry file triggers rebuild + rerun.
- Editing a LOCAL imported file triggers rebuild + rerun.
- `--no-run` rebuilds without executing.
- A syntax error prints the `lumen compile` diagnostic and the watcher survives;
  fixing it rebuilds.
- SIGINT stops the watcher and kills the child.

The full `zig build conformance` suite must remain green (no regressions).
