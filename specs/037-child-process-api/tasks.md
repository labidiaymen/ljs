# Tasks: child_process API

## Phase 1

- [x] T1 Added `"child_process"` to the parser's `isStdNamespace` list. New
  `childProcessCallType` in `lumen_check_stdlib.zig`, wired into
  `staticCallType`.
- [x] T2 `registerLumenSpawnResult` -- synthetic 3-field record type
  (stdout: string, stderr: string, status: i32), following
  `registerLumenPathParts`'s exact pattern.
- [x] T3 `child_process.spawnSync(command, args)` -- `(string, string[]) ->
  __LumenSpawnResult`. Spawns with piped stdout/stderr, reads each to
  completion via `allocRemaining`, then `wait`.
- [x] T4 Verified: `spawnSync("echo", ["hello", "world"])` produced the
  right stdout and `status: 0`; `spawnSync("sh", ["-c", "exit 7"])` gave
  `status: 7`; `spawnSync("sh", ["-c", "echo oops 1>&2"])` captured `oops`
  on `stderr`; a nonexistent command produced the spawn-failure fallback
  (`status: -1`, empty stdout/stderr).
- [x] T5 Confirmed (not assumed) what happens under `--wasm`: it compiles
  cleanly and runs without crashing (checked with wasmtime), but every
  call fails at the spawn step -- WASI has no process-spawning capability,
  so `status` is always `-1` there. Same "compiles, but non-functional"
  shape as `os.uptime()`/`process.pid()`, tagged the same
  target-wasm-limited way, not the async fs trio's compile-time rejection.
- [x] T6 `zig build test` passes. `zig build conformance` run clean (no
  concurrent builds, same pre-existing failures, no new ones).
- [x] T7 Updated `website/stdlib.html`: new `child_process` quick-jump list
  + function block with the wasm-limited pill; updated Planned table;
  added to the docs-nav sidebar.
- [x] T8 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `exec`/`execSync` (needs shell-quoting),
async `spawn` with streaming stdio (needs event-loop integration like the
async fs trio got), `cwd`/`env`/`timeout` options (the underlying
`SpawnOptions` already supports these, just not exposed yet), stdin piping,
and signal-based exit status.
