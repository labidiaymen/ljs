# Tasks: `lumen watch`

## T1 — Watch-set collection
- [x] `collectWatchPaths`: walk the entry file's LOCAL import closure, collecting
      resolved local paths; skip `https://` imports; tolerate read/parse errors.

## T2 — Change detection
- [x] `fileHash`: 64-bit Wyhash of file contents (0 when unreadable).
- [x] `snapshotWatchSet`: build (path -> hash) map for the current watch set.

## T3 — Rebuild + run
- [x] `watchRebuild`: rebuild via the existing `compileFile` path; on success and
      when running, kill the previous child and spawn `./<stem>` with inherited
      stdio; on failure keep the previous run and report a status line.

## T4 — Signal handling
- [x] `WatchSignal`: process-global `interrupted` flag + tracked child pid.
- [x] POSIX `SIGINT`/`SIGTERM` handler kills the child and flips the flag.

## T5 — Poll loop
- [x] `watchProject`: initial build, `watching N files` line, ~150 ms poll loop
      recomputing the watch set each iteration, rebuild on change, clean stop +
      child kill on interrupt.

## T6 — CLI wiring
- [x] `watch` branch in `main` dispatch parsing `--no-run`,
      `--release-fast`/`--release-safe`, and the source file.
- [x] Usage/help text lists `lumen watch [--no-run] <file.ts>`.

## T7 — Docs
- [x] README `lumen watch` note.
- [x] website/index.html quickstart mention (Zig invisible, no emoji).

## T8 — Verification
- [x] `zig build` + `zig build fmt-check` clean.
- [x] `zig build conformance` green (206 cases).
- [x] Manual: entry edit, local-import edit, `--no-run`, build-error recovery,
      SIGINT all verified.
