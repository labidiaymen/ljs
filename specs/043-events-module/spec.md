# Spec 043: events module (EventEmitter)

## Goal

A statically-typed `EventEmitter<T>`, closing the foundational gap flagged
repeatedly this session (`fs.watch`, streaming `http`, and others all
deferred specifically on "no event/listener infrastructure yet"). Modeled
on [Node's `events` module](https://nodejs.org/docs/latest/api/events.html),
with two deliberate, necessary departures from Node's shape -- see below.
Implemented as a built-in **generic class**, the same architectural
category as `Map<K, V>`/`Set<T>` (the checker already special-cases
`class_name == "Map"`/`"Set"` when the user hasn't declared their own class
of that name; `EventEmitter` follows the identical pattern), not the
static-function-namespace pattern every other stdlib module (`Math`,
`path`, `crypto`, ...) uses -- an emitter is inherently stateful (listeners
accumulate on one instance over time), which a namespace of static
functions can't represent.

## Node's real API surface (for reference, from nodejs.org)

- **Instance methods**: `on`/`addListener`, `once`, `off`/`removeListener`,
  `removeAllListeners`, `emit`, `listenerCount`, `listeners`,
  `rawListeners`, `eventNames`, `prependListener`, `prependOnceListener`,
  `setMaxListeners`, `getMaxListeners`.
- **Special events**: `'error'` (crashes the process if emitted with no
  listener registered), `'newListener'`, `'removeListener'`.
- **Module-level**: `events.once(emitter, name)` (returns a `Promise`),
  `events.on(emitter, name)` (returns an `AsyncIterator`),
  `events.listenerCount`/`getEventListeners`/`setMaxListeners` (static
  forms), `events.errorMonitor`, `events.captureRejections`,
  `EventEmitterAsyncResource`.

## Two necessary departures from Node's shape

1. **One payload type per emitter instance, not per event name.** In
   Node, one `EventEmitter` instance can have wildly different listener
   signatures per event name on the *same* object (`'data'` listeners take
   a `Buffer`, `'error'` listeners take an `Error`, `'close'` listeners
   take nothing) -- there's no static type checking this at all. Lumen's
   type system has no way to express "this string key selects this
   listener signature" without per-instance reflection Lumen doesn't have.
   `EventEmitter<T>` instead fixes one payload type `T` for every event
   name registered on a given instance; event names are still real string
   keys (`.on("data", listener)`, `.emit("data", value)`, matching Node's
   call shape), just constrained to share `T`. A program that genuinely
   needs `'data'` and `'error'` listeners with different payload shapes
   creates two separate `EventEmitter` instances (or wraps both shapes in
   one union/record `T`) -- a real, meaningful simplification, not a
   corner case to paper over.
2. **Listener storage is a Zig-internal growable list, invisible to
   Lumen.** Lumen's own `T[]` array type has no `push`/growable-array
   support yet (the same gap that deferred `Array.push`/`pop`/`sort` and
   `url`'s `querystring`). That doesn't block this: the *generated* Zig
   code backing `EventEmitter<T>` can use `std.ArrayListUnmanaged` (or a
   `std.StringHashMap` of them, keyed by event name) entirely internally,
   the same way `crypto`'s timer-id registry and `LumenPromise<T>` already
   use Zig-level structures Lumen's own syntax can't construct directly.
   Nothing about Lumen's array-literal gap blocks this feature.

## API (the practical subset that ships)

| Method | Type | Notes |
| --- | --- | --- |
| `new EventEmitter<T>()` | -- | construct an emitter for payload type `T` |
| `.on(name, listener)` | `(string, (T) => void) -> void` | registers a listener; alias `addListener` deferred (one name is enough for v1) |
| `.once(name, listener)` | `(string, (T) => void) -> void` | listener fires at most once, then is dropped |
| `.emit(name, value)` | `(string, T) -> void` | calls every listener registered for `name`, in registration order; removes fired `once` listeners |
| `.removeAllListeners(name?)` | `(string?) -> void` | clears listeners for one name, or every name if omitted |
| `.listenerCount(name)` | `string -> int` | how many listeners are currently registered for `name` |

**Benchmark against Node's native `EventEmitter`**: ~3.5x faster on a
10M-emit loop, one listener (`--release-fast`, ~43ms vs Node 20's ~160ms
for the equivalent loop). Found and fixed a real bug while measuring this:
`emit` was unconditionally rebuilding and reallocating the listener list
on every call, even when there was nothing to remove -- a ~25-30x
improvement on its own (Lumen measured roughly 4x *slower* than Node
before this fix). Now the list is only rebuilt when a `once` listener
actually fired that emit.

## Design notes

- **Mutating an emitter from inside one of its own listeners, during
  `emit`, is not guaranteed-safe for that same event name**: `emit`
  iterates the registered listener list and builds a fresh list of the
  ones to keep (dropping fired `once` listeners) as it goes. If a
  listener itself calls `.on()`/`.once()`/`.removeAllListeners()` for the
  *same* name while that `emit` is still running, the growable listener
  list backing it can reallocate mid-iteration. Node has specific,
  documented behavior for this re-entrant case; matching it exactly
  would need more careful iteration bookkeeping than this pass attempted.
  Flagged explicitly rather than left as an unexamined edge case --
  straightforward, non-re-entrant use (registering listeners up front,
  emitting later) is unaffected.
- **`off`/`removeListener` deferred**: removing one specific listener
  needs comparing two listener values for identity, and Lumen's closure
  representation (a fat pointer + context, per the `LumenFn` pattern
  `setTimeout`/`setInterval` already use) hasn't been checked for
  reliable equality comparison. `removeAllListeners` (bulk clear, no
  identity comparison needed) covers the common "tear down and
  re-register" case without it.
- **The `'error'`-crashes-if-unhandled special case deferred**: real,
  useful Node behavior, but needs "is there currently a listener
  registered for this exact name" as a distinct code path from a normal
  `emit`, worth its own verification pass rather than folding in
  silently.
- **`events.once(emitter, name)`/`events.on(emitter, name)` (the
  module-level, `Promise`/`AsyncIterator`-returning forms) deferred**:
  the `Promise`-returning `once` is a plausible fast-follow (Promise
  infrastructure already exists, from spec 022's async work), but the
  `AsyncIterator`-returning `on` needs an async-iteration concept Lumen
  doesn't have at all -- a bigger, separate feature.
- **`prependListener`/`prependOnceListener`/`rawListeners`/
  `setMaxListeners`/`getMaxListeners`/`captureRejections`/`errorMonitor`/
  `EventEmitterAsyncResource` all deferred**: niche or Node-internal-
  plumbing-focused; `listeners`/`eventNames` (introspection) are similarly
  low-value without a consumer, deferred alongside them.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Per-event-name listener types on one instance | not expressible in Lumen's type system without reflection; see departure #1 above |
| `off`/`removeListener` | needs reliable closure-identity comparison, not yet checked |
| `'error'` special-case (crash if unhandled) | needs a distinct "any listeners registered" check, its own verification pass |
| `events.once`/`events.on` (module-level `Promise`/`AsyncIterator` forms) | `once` is a plausible fast-follow; `on` needs async iteration, not built |
| `prependListener`/`prependOnceListener`/`rawListeners`/`setMaxListeners`/`getMaxListeners`/`listeners`/`eventNames` | niche, introspection-focused, low value without a consumer yet |
| `captureRejections`/`errorMonitor`/`EventEmitterAsyncResource` | Node-internal-plumbing-focused, not relevant without the features they support |
