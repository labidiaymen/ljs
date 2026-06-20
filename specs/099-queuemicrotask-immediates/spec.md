# Spec 099 — queueMicrotask + setImmediate/clearImmediate, event-loop phase model — Node axis, slice 2

Status: In progress
Owner: Aymen

## Context
Slice 1 (`specs/098-event-loop-timers/`) gave the host event loop + timers. Slice 2 rounds out the
**scheduling layer**: the standard `queueMicrotask` (WHATWG/Node) and Node's `setImmediate`/
`clearImmediate`, and restructures `runEventLoop` into an explicit phase model so the three
queues (microtasks, immediates, timers) interleave per the Node/HTML ordering.

## Design

### Ordering (the loop invariant)
Per turn, in priority order: **microtasks → one immediate → one due timer**, sleeping only when
nothing is immediately runnable. Microtasks are ALWAYS drained to empty before any macrotask
(immediate or timer). Immediates (Node "check" phase) run before non-due timers.

`runEventLoop`:
```
loop:
  drainJobs()                         // microtasks to empty (Promise reactions + queueMicrotask)
  if an immediate is queued: pop+run one (unless cancelled); continue   // re-drain microtasks
  compact cancelled timers
  if no timers remain: break          // microtasks + immediates already empty here
  let t = earliest-deadline timer; now = monotonicMs()
  if t.deadline <= now: reschedule/remove t, run it; continue
  sleepMs(t.deadline - now)           // nothing runnable now; wait for the next timer
```

### `queueMicrotask(callback)` (WHATWG / ECMA-ish, Node + browsers)
Enqueue a **microtask** that calls `callback()` (no args, `this` = undefined). A non-callable arg →
TypeError. It joins the SAME Job queue as Promise reactions (so it interleaves correctly with
`.then`). Implemented as a new `Job.microtask: *Object` variant handled in `drainJobs`. An exception
from the callback is reported to stderr (HostReportErrors), the drain continues. (This makes
`drainJobs` — shared with the Test262 path — handle the new variant, but the variant is only ever
enqueued by `queueMicrotask`, a host global Test262 never calls.)

### `setImmediate(callback, ...args)` / `clearImmediate(id)` (Node)
A separate **immediate** queue (FIFO) on the interpreter, fired in the loop's check phase before
timers. Returns a numeric id; `clearImmediate(id)` cancels. An immediate scheduled from within a
callback runs on the next loop turn (not re-entrantly), matching Node.

## Acceptance
- `queueMicrotask(()=>log("mt")); log("sync")` via `ljs run` → `sync` then `mt`.
- `Promise.resolve().then(()=>log("p")); queueMicrotask(()=>log("q"))` → FIFO `p` then `q` (same queue).
- `queueMicrotask(5)` → TypeError.
- `setImmediate(()=>log("imm")); setTimeout(()=>log("to"),0)` → `imm` before `to` (check before timers).
- `setImmediate(()=>log("a")); queueMicrotask(()=>log("m"))` → `m` (microtask) before `a` (immediate).
- `clearImmediate(setImmediate(()=>log("X")))` → nothing prints.
- **Regression:** `language/` + `built-ins/` 0 regressions (host globals inert on the Test262 path);
  build/test/lint/bench green.

## Out of scope (later)
- Node `Timeout`/`Immediate` OBJECTS with `.ref()`/`.unref()`/`.hasRef()` + `[Symbol.toPrimitive]`
  (and the "unref'd handle doesn't keep the loop alive" semantics — our loop runs until queues empty;
  a follow-up slice can model refcount-based exit). `process.nextTick` (a pre-microtask queue) —
  lands with the `process` slice.
