# Spec 038: timers completion

## Goal

Close a real, already-live gap rather than add a new namespace:
`setTimeout` exists, but there is no way to cancel one, and there is no
repeating timer at all. Add `clearTimeout`, `setInterval`, `clearInterval`,
reusing `setTimeout`'s proven event-loop timer machinery. Global functions,
not a namespace, matching how `setTimeout` itself is already exposed.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `setTimeout(cb, ms)` | `(() => void, int) -> int` | unchanged behavior, now returns a handle instead of `void` |
| `clearTimeout(id)` | `int -> void` | cancels a pending `setTimeout` |
| `setInterval(cb, ms)` | `(() => void, int) -> int` | repeats `cb` every `ms` until cancelled |
| `clearInterval(id)` | `int -> void` | cancels a running `setInterval` |

## Design notes

- **Handle shape**: a plain `int`, like Lumen's file descriptors
  (`fs.openSync`'s return value) -- not an opaque `Timeout` object like
  Node's, since there's no natural place in the type system for one yet.
  `clearInterval`/`clearTimeout` are actually the same function under the
  hood (both just flip a cancellation flag looked up by id); kept as two
  names purely to match Node's API, matching how `os.platform()`/
  `process.platform()` are intentionally two names for the same thing.
- **Cancellation is a flag, not real timer removal**: the underlying event
  loop's timer-cancel operation is itself asynchronous (needs its own
  completion and callback to confirm cancellation completed) -- real
  removal would add meaningful complexity for a synchronous, fire-and-forget
  `clearTimeout` call. Instead, every timer holds a pointer to a small,
  uniformly-shaped cancellation cell; `clearTimeout`/`clearInterval` just
  sets its flag, and the timer's own fire callback checks the flag before
  doing anything (running the user callback, or rescheduling itself for
  `setInterval`). The OS timer still technically fires once more
  internally; nothing is visible to the user program. A deliberate,
  documented simplification, not an oversight.
- **`setTimeout`'s return type changes from `void` to `int`**: existing
  fire-and-forget call sites (`setTimeout(cb, ms);` as a bare statement,
  ignoring the result) are unaffected, since Lumen allows discarding an
  expression statement's value the same as any other function call.
- **`setInterval` reschedules itself from inside its own fire callback**:
  verified with a real, running program (not assumed) that calling the
  timer's `run` again from within its own completion callback, then
  returning `.disarm` for that invocation, correctly re-arms it for the
  next tick rather than leaking or double-firing -- confirmed 3 ticks fire
  before `clearInterval` (called from a separately-scheduled `setTimeout`)
  stops a 4th. This is a different, previously-unused pattern in this
  codebase (every prior timer/async user was one-shot), so it needed
  direct execution to confirm rather than assuming the completion API
  behaves the way `setTimeout`'s one-shot use suggested.
- **Two unrelated, pre-existing language limitations hit while writing the
  verification program, worth a note for whoever writes the next
  closure-heavy test**: a block-bodied arrow function (`() => { ... }`)
  fails to parse when used as an inline callback argument or assigned to a
  variable (only single-expression arrow bodies work, e.g.
  `() => report(label, n)`); and a plain top-level `function` cannot read
  or write a top-level `let`/`const` script variable at all (it compiles
  to a standalone Zig function with no access to `main`'s locals). Neither
  is new in this milestone or specific to timers -- routed around both by
  keeping every callback either a bare top-level function taking its state
  as a parameter, or a single-expression arrow closing over a variable
  local to its *own* enclosing function (which does work, matching the
  existing `makeAdder`-style closure example).

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Real (non-flag-based) timer cancellation | would need the loop's async cancel-completion machinery; the flag approach is simpler and behaviorally identical from the program's perspective |
| `setImmediate`/`process.nextTick` | a different scheduling primitive (microtask-like, not timer-based); not attempted here |
| Passing extra arguments to the callback (`setTimeout(cb, ms, ...args)`) | Lumen's closures already capture what they need; Node's extra-args form is largely redundant with that |
