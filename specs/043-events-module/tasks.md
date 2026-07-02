# Tasks: events module (EventEmitter)

## Phase 1

- [ ] T1 Read exactly how `Map<K, V>`/`Set<T>` are wired up as built-in
  generic classes (checker special-case on `class_name`, codegen, runtime
  Zig type) before writing any new code -- `EventEmitter<T>` should follow
  that same architecture, not invent a new one.
- [ ] T2 Add the `EventEmitter` built-in-class special-case (checker:
  `class_name == "EventEmitter"` when the user hasn't declared their own
  class of that name, mirroring the existing `Map`/`Set` checks).
- [ ] T3 Runtime type: a generic Zig struct (`LumenEventEmitter(T)`,
  mirroring `LumenPromise(T)`'s existing shape) wrapping a
  `std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ListenerEntry))`,
  where `ListenerEntry` holds the closure plus a `once: bool` flag.
- [ ] T4 `new EventEmitter<T>()`, `.on(name, listener)`, `.once(name,
  listener)`.
- [ ] T5 `.emit(name, value)` -- calls every currently-registered listener
  for `name` in registration order, then removes any that were
  registered via `.once`. Decide and document the exact semantics if a
  listener registers or removes another listener *during* an `emit` call
  (Node has specific, documented behavior here worth matching or
  deliberately deviating from with a note, not leaving undefined).
- [ ] T6 `.removeAllListeners(name?)`, `.listenerCount(name)`.
- [ ] T7 Verify: an emitter with two listeners on the same name both
  fire, in registration order, with the right payload; a `once` listener
  fires exactly once and is gone on the second `emit`; `listenerCount`
  reflects additions/removals accurately; emitting a name with zero
  listeners is a safe no-op, not a crash; two different event names on
  one instance don't cross-fire each other's listeners.
- [ ] T8 Confirm `--wasm` compiles and runs correctly (execute it via
  wasmtime, not just compile-check) -- this is pure in-memory state, no
  syscalls, so it should be fully portable like `crypto`/`url`, but
  verify rather than assume given this is a new kind of built-in
  (stateful class, not a static-function namespace).
- [ ] T9 `zig build test` passes. `zig build conformance` run clean.
- [ ] T10 Update `website/stdlib.html`: a new section (probably grouped
  near `async`/Collections given it's a built-in generic class like
  `Map`/`Set`/`Promise`, not a static-function module); explain the
  one-payload-type-per-instance departure from Node clearly, the same way
  `path.resolve`'s cwd-anchoring deviation gets its own callout.
- [ ] T11 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `off`/`removeListener` (needs
closure-identity comparison), the `'error'`-crashes-if-unhandled special
case (needs its own verification pass), `events.once`/`events.on`
module-level forms (`once` is a plausible fast-follow via existing Promise
infra; `on` needs async iteration, not built), and the remaining
niche/introspection/plumbing-focused methods.

## Unblocks (for context, not tasks here)

Once this ships, revisit whether `fs.watch`/`watchFile` and a streaming
`http` server (spec 042's Phase 3) are now reachable -- both were
explicitly deferred on "no event/listener infrastructure yet," which this
spec exists to resolve.
