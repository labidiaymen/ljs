# Spec 037: child_process API

## Goal

A first, sync-only slice of Node's `child_process` module:
`child_process.spawnSync(command, args)`. The biggest remaining capability
gap in the stdlib so far: Lumen programs currently cannot invoke another
program at all. `std.process.spawn`/`Child.wait` are proven, working
primitives (the playground's own compile service already uses them to run
the compiler itself), so the implementation risk is low even though this is
a bigger API surface than `crypto`/`url` were. Confirmed (not assumed) that
it compiles under `--wasm` and runs without crashing, but every call falls
back to a spawn failure there -- WASI has no process-spawning capability at
all, so `status` is always `-1` on that target. Same "compiles, but
non-functional" shape as `os.uptime()`/`process.pid()`, not the async fs
trio's compile-time rejection.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `child_process.spawnSync(command, args)` | `(string, string[]) -> { stdout, stderr, status }` | runs `command` with `args` (no shell involved, matching Node's real `spawnSync`, not `execSync`'s shell-string form), waits for it to exit, returns a record |

Record shape, matching Node's real `spawnSync` return object (a subset of
its fields):

- `stdout`: everything the child wrote to stdout, as a string.
- `stderr`: everything the child wrote to stderr, as a string.
- `status`: the exit code as an `int`, or `-1` if the process could not be
  spawned or exited abnormally (signal, not builtin range 0-255) --
  Node's real field can also be `null`/hold a signal name; Lumen has no
  optional-int-or-string union to represent that, so both failure modes
  collapse to `-1`.

`spawnSync`, not `execSync`, was chosen as the v1 entry point specifically
because it does not throw on a non-zero exit (Node's `execSync` does) --
every other Lumen stdlib function so far returns a fallback/degraded value
on failure rather than throwing, and `spawnSync`'s record-of-everything
shape fits that pattern directly, while `execSync`'s throw-on-failure
semantics would be the only stdlib function to behave that way.

## Design notes

- **No shell**: `args` is a real `string[]`, passed directly as `argv[1..]`
  to the child process, the same as Node's `spawnSync` (not `exec`/
  `execSync`, which run the command through `/bin/sh -c`). Safer by
  default (no shell-injection surface) and avoids needing any shell-quoting
  logic.
- **stdout/stderr captured sequentially, not concurrently**: read stdout to
  completion, then stderr, then call `wait`. This is a genuine, documented
  simplification, not an oversight: a command that writes more than one
  pipe's kernel buffer (about 64KB on Linux) to stderr *while* this is still
  blocked reading stdout could deadlock. Real-world commands' stderr output
  is typically small (warnings/diagnostics, not primary output), so this is
  an acceptable v1 trade-off, not a silent correctness gap -- revisit with
  concurrent/polled reads if it proves too limiting.
- **`status: -1` on spawn failure**: e.g. command not found. Matches how
  `fs`/`path`/`url` degrade to an empty/fallback value on failure rather
  than raising an exception Lumen has no path to express from a stdlib
  builtin.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `child_process.exec`/`execSync` (shell-string form) | needs shell-quoting/escaping logic to be safe; `spawnSync`'s array-of-args form sidesteps this entirely for v1 |
| `child_process.spawn` (async, streaming stdio) | needs the same event-loop integration `fs.readFile`/`writeFile`/`appendFile` got, plus a design for streaming (not one-shot) stdio -- a real follow-up, not attempted here |
| `cwd`/`env`/`timeout` options | `SpawnOptions` supports all of these already at the primitive level; just not exposed as `spawnSync` parameters yet, straightforward to add |
| stdin piping (writing to the child) | `spawnSync`'s one-shot, no-interaction model doesn't need it; would matter for a streaming `spawn` |
| signal-based `status` (Node's `signal` field) | Lumen has no optional-string-or-int union to represent "exited with code N" vs "killed by signal S"; both collapse to `-1` for now |
