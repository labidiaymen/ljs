# Tasks: timers completion

## Phase 1

- [x] T1 `setTimeout(cb, ms)` return type changed from `void` to `int` (a
  handle). Updated the checker (`lumen_check_expr.zig`) and reused the
  existing generic non-void expression-statement handling in
  `lumen_emit_stmt.zig` (no change needed there).
- [x] T2 Added a uniform `__TimerCancelFlag` cell + a global id-to-flag
  registry (`__timer_ids`, an `AutoHashMapUnmanaged(i32, *__TimerCancelFlag)`)
  in `lumen_compiler.zig`. `__setTimeout` creates one, registers it,
  returns the id; its fire callback checks the flag before calling the
  user callback.
- [x] T3 `clearTimeout(id)` -- global function; the checker renames the
  call to `__clearTimer` (same pattern as `expect`/`__expectStrEqual`),
  which falls through to the emitter's generic call-emission path with no
  dedicated emit branch needed.
- [x] T4 `setInterval(cb, ms)` -- same registration pattern as
  `setTimeout`, but the fire callback checks the flag, calls the user
  callback, checks the flag again (in case the callback itself cleared
  it), then re-arms the same timer for another `ms`.
- [x] T5 `clearInterval(id)` -- same underlying `__clearTimer` as
  `clearTimeout`, a second checker entry point matching Node's naming.
- [x] T6 Verified with a real running program: a `setInterval` ticked 3
  times before a separately-scheduled `setTimeout` called `clearInterval`
  and stopped it (confirms both repetition and cross-callback
  cancellation); a `setTimeout` cancelled before its delay elapsed never
  fired (confirmed no "BUG" output); `clearTimeout`/`clearInterval` called
  with an unregistered id did not crash. Had to work around two unrelated,
  pre-existing parser/scoping limitations to write a valid test program
  (see spec.md) -- neither is new in this milestone. Execution required
  `--security-opt seccomp=unconfined` on the container: this sandbox's
  default seccomp profile blocks the io_uring syscalls the async runtime
  needs entirely (a environment-level restriction hit repeatedly this
  session for async fs too), not something wrong with the code itself.
- [x] T7 `zig build test` passes. `zig build conformance` run clean under
  the same unconfined container (no concurrent builds) -- confirmed
  `setTimeout`'s changed return type didn't break any existing case.
- [x] T8 Updated `website/stdlib.html`'s existing async/await section
  (not a new section) with the four functions.
- [x] T9 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: real (non-flag-based) cancellation,
`setImmediate`/`process.nextTick`, extra callback arguments.
