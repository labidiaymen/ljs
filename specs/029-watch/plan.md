# Implementation Plan: `lumen watch`

**Branch**: `main` (milestone 029) | **Spec**: [spec.md](./spec.md)

## Summary

Add a `watch` CLI action that rebuilds the program whenever the entry file or any
of its local imports changes, re-running the produced binary by default. The
build path is the existing `compileFile` so diagnostics and output match
`lumen compile` exactly. The feature lives entirely in `src/lumen.zig`; no
changes to the parser, checker, or backend.

## Technical Context

- **Language/Version**: Zig 0.16.0.
- **Dependencies**: Zig standard library only (`std.Io` for sleep/spawn/read,
  `std.posix` for signal handling, `std.hash.Wyhash` for content hashing).
- **Watch mechanism**: ~150 ms content-hash polling. No platform fs-event APIs.
- **Process model**: `std.process.Child` for the spawned binary; killed and
  re-spawned on each successful rebuild.

## Design

### Watch-set collection — `collectWatchPaths`

A read-only walk of the entry file's LOCAL import closure, mirroring the
resolution logic in `appendExpandedSource`/`parseImportSpec` but collecting
resolved local paths instead of inlining. `https://` specifiers are skipped.
Tolerant of errors (a malformed import or missing file just stops that branch);
the rebuild itself surfaces the real diagnostic.

### Change snapshot — `snapshotWatchSet` / `fileHash`

For each path in the watch set, store a 64-bit Wyhash of its contents. The poll
loop recomputes the set and hashes every iteration and compares against the
previous snapshot; a count change or any hash mismatch triggers a rebuild.

Content hashing is used instead of mtime because `statFile` returns stale mtimes
after a `zig build-exe` child runs under this I/O (file reads stay fresh).

### Rebuild — `watchRebuild`

Calls `compileFile(..., .build_exe, ...)` (identical to `lumen compile`). On
success with running enabled, kills the previous child and spawns `./<stem>` with
inherited stdio, tracking its pid for signal handling. On failure, leaves the
previous run untouched and reports a one-line status.

### Loop + signals — `watchProject`

Installs a SIGINT/SIGTERM handler (POSIX) that kills the tracked child and sets a
global `interrupted` atomic. Performs the initial build, prints
`watching N files`, then polls until interrupted, killing the child on exit.

## CLI Wiring

A `watch` branch in the `main` dispatch parses `--no-run`,
`--release-fast`/`--release-safe`, and the source argument, then calls
`watchProject`. Usage/help text lists the new action.

## Testing

- `zig build` and `zig build fmt-check` clean.
- `zig build conformance` stays green (206 cases).
- Manual watcher verification per spec (entry edit, local-import edit,
  `--no-run`, build error recovery, SIGINT).

## Complexity Tracking

| Decision | Why | Rejected alternative |
|----------|-----|----------------------|
| mtime polling spec, content-hash impl | std has no portable watcher; stat mtime is stale post-build on this I/O | fs-event APIs (not portable in std); mtime (stale here) |
| Reuse `compileFile` | Diagnostics/output identical to `compile` | A separate watch-only build path would drift |
