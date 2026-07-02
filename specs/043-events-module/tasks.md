# Tasks: events module (EventEmitter)

## Phase 1

- [x] T1 Read exactly how `Map<K, V>`/`Set<T>` are wired up as built-in
  generic classes before writing code: a dedicated `types.Type` variant
  (`.map_type`/`.set_type`), not the general `class_type`/user-generic-
  class path; construction special-cased in `new_expr` checking
  (`class_name == "Map"`/`"Set"` when the user hasn't declared their own
  class of that name); methods dispatched via `mapMethod`/`setMethod`,
  which set `mc.container_type = obj_type` as a sentinel the *existing*,
  fully generic emit code already reads to call straight through to the
  runtime method (`obj.methodName(args...)`) -- meaning method-call and
  construction codegen needed **zero** `lumen_emit.zig` changes.
  `EventEmitter<T>` followed this exact architecture.
- [x] T2 Added `.event_emitter_type: *const Type` to the `Type` union;
  the compiler's own exhaustive-switch errors (`same`/`mangle`/`zigName`/
  `toAnnotation`) located every place needing a matching arm. Added
  `isEventEmitter`. Added the `EventEmitter` built-in-class special-case
  in `new_expr` checking, mirroring `Map`/`Set` exactly.
- [x] T3 Runtime type: `LumenEventEmitter(comptime T: type)`, a
  `std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Listener))` where
  `Listener = struct { ctx: *const anyopaque, call: *const fn(*const
  anyopaque, T) void, once: bool }`. Listener values arrive via `anytype`
  parameters on `on`/`once` (the same closure-handling pattern
  `Map`/`Set`'s `forEach` already uses) and are destructured into the
  uniform `Listener` shape -- sidesteps any nominal-type mismatch between
  the caller's actual `LumenFn_<T>__R__void` closure value and this
  struct's own field names.
- [x] T4 `new EventEmitter<T>()`, `.on(name, listener)`, `.once(name,
  listener)`.
- [x] T5 `.emit(name, value)` -- calls every currently-registered listener
  for `name` in registration order, then removes any that were
  registered via `.once`, by iterating the original list and building a
  fresh "keep" list rather than removing in place. **Documented, not
  fully solved: mutating the same emitter (adding/removing listeners for
  the same name) from inside a listener during that name's `emit` call
  is not guaranteed-safe** -- the growable listener list can reallocate
  mid-iteration. Node has specific documented behavior for this
  re-entrant case; matching it exactly would need more careful iteration
  bookkeeping than this pass attempted. Flagged in spec.md rather than
  silently left as an unexamined edge case.
- [x] T6 `.removeAllListeners(name?)` (renames to a distinct
  `removeListenersFor` runtime method for the 1-arg form, since Zig has
  no default-parameter overloading and the generic method-call emit path
  forwards exactly the args written), `.listenerCount(name)`.
- [x] T7 Verified in one program: two listeners on the same name (a
  permanent `on` and a `once`) both fired on the emit where both were
  registered, in registration order, with the right payload; the `once`
  listener was gone on the next `emit`; `listenerCount` reflected every
  addition/removal exactly; emitting a name with zero listeners was a
  safe no-op; two different event names (`"greet"`/`"farewell"`) on one
  instance never cross-fired or cross-cleared each other.
- [x] T8 Confirmed identical output under `--wasm` via wasmtime (not just
  compile-checked) -- fully portable, pure in-memory state, no syscalls.
- [x] T9 `zig build test` passes. `zig build conformance` run clean under
  an unconfined-seccomp container.
- [x] T10 Updated `website/stdlib.html`.
- [x] T11 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `off`/`removeListener` (needs
closure-identity comparison), the `'error'`-crashes-if-unhandled special
case (needs its own verification pass), `events.once`/`events.on`
module-level forms (`once` is a plausible fast-follow via existing Promise
infra; `on` needs async iteration, not built), the remaining
niche/introspection/plumbing-focused methods, and safe re-entrant
add/remove-during-emit semantics (see T5).

## Unblocks (for context, not tasks here)

Once this ships, revisit whether `fs.watch`/`watchFile` and a streaming
`http` server (spec 042's Phase 3) are now reachable -- both were
explicitly deferred on "no event/listener infrastructure yet," which this
spec exists to resolve.
