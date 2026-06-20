# Spec 100 — `process` global + `global` alias + `process.nextTick` — Node axis, slice 3

Status: In progress
Owner: Aymen

## Context
Slices 1–2 (specs 098/099) gave the event loop + scheduling (timers, queueMicrotask, immediates).
Slice 3 adds the **`process`** host object (the most-used Node global), the **`global`** alias for
`globalThis`, and **`process.nextTick`** (the pre-microtask queue that sequences before Promise jobs).
Pure std, no new dependency. **Buffer is deferred to its own slice (101)** for reviewability.

## Architecture decision — host globals install on the HOST path only
`process` needs argv / env / cwd from the CLI entry, so it CANNOT live in the shared
`builtins.setup` (used by Test262 too). Introduce **`host_setup.installHostGlobals(self, ctx)`**,
called by `runHost` AFTER `builtins.setup`, where `ctx` carries argv + env pairs + cwd (built in
`main` from `std.process.Init`). **Move the slice-1/2 timer + console globals into this host setup
too** — so Test262 realms become pure ECMAScript (no host globals at all), which is cleaner than the
"inert but present" status quo and keeps the 0-regression guarantee. `ljs eval` (no event loop) also
calls `installHostGlobals` so `console.log` works there.

## `process` surface (slice 3)
- `process.argv` — `[execPath, scriptPath, ...extraArgs]` (array). `process.argv0`, `process.execPath`.
- `process.env` — a plain object snapshot of the OS environment (key→value strings), built in `main`.
- `process.platform` (`"win32"`/`"linux"`/`"darwin"`), `process.arch` (`"x64"`/`"arm64"`).
- `process.version` (a Node-compat string, e.g. `"v22.0.0"`), `process.versions` (`{ node, v8, ljs }`).
- `process.pid` (best-effort; 0 if unavailable).
- `process.cwd()` — native; the current working directory.
- `process.exit([code])` — native; flush host writers, then `std.process.exit(code|0)`.
- `process.nextTick(cb, ...args)` — native; enqueue on the **nextTick queue** (see below).
- `process.stdout.write(s)` / `process.stderr.write(s)` — native; write the string to the run's
  shared stdout/stderr writer (return `true`). `console.log` may route through `process.stdout`.
- `globalThis.global = globalThis` (Node alias).

## `process.nextTick` ordering
Node drains the **nextTick queue fully before each microtask (Promise) checkpoint**, i.e. nextTick
callbacks run before Promise reactions scheduled in the same turn. Add `next_tick_queue:
ArrayListUnmanaged(NextTickEntry)` to the interpreter. Drain it (to empty, including ticks they
enqueue) at the TOP of each `runEventLoop` iteration, BEFORE `drainJobs`. So the loop turn becomes:
**nextTick → microtasks → one immediate → one due timer**. (A nextTick scheduled with no event loop
running, e.g. in `ljs eval`, simply never fires — acceptable.)

## Acceptance
- `console.log(process.argv.length >= 2, process.platform, typeof process.cwd())` → `true win32 string`
  (on the dev box).
- `process.nextTick(()=>log("nt")); Promise.resolve().then(()=>log("p")); log("sync")` →
  `sync`, `nt`, `p` (nextTick before the Promise microtask).
- `process.env.PATH` is a non-empty string (env populated).
- `global === globalThis` → `true`.
- `process.stdout.write("x\n")` prints `x`.
- `process.exit(3)` exits with code 3 (no further output).
- **Regression:** moving host globals off the shared path must keep `language/` + `built-ins/` at
  0 regressions (Test262 never referenced them); build/test/lint/bench green.

## Out of scope (later slices)
- `Buffer` (slice 101). `process.stdin`, streams beyond `.write`, `process.on`/EventEmitter,
  `process.hrtime`, `process.memoryUsage`, signal handling. Timeout/Immediate ref/unref objects.
