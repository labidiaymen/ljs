# Spec 046: Streams

## Goal

A real `ReadableStream`/`WritableStream` pair, closing the single most-
cited blocker across the whole session: `fs.createReadStream`/
`createWriteStream` (deferred in spec 031 on "no `Stream` abstraction in
the language"), streaming `http` request/response bodies (deferred in
spec 042 the same way), and general chunked processing. The biggest
remaining lever: everything that touches a file or a socket today reads
or writes the *whole* thing in one call.

Scoped to **file-backed streams only** for this spec (`fs.createReadStream`/
`createWriteStream`) -- not a generic `Stream<T>` that also wraps network
connections. Extending this same shape to `http` request/response bodies
is real, valuable, explicitly named as the reason this matters, and
explicitly **not attempted here**: see "Not planned."

## Why file-backed only, not also network-backed, in one pass

`ReadableStream`/`WritableStream` need to be built the same way
`Map`/`Set`/`EventEmitter<T>` are: a dedicated, non-generic Zig type
(`LumenReadableStream`/`LumenWritableStream`) wrapping a `std.Io.Reader`/
`Writer` and its owning file handle, heap-allocated so the object survives
across multiple separate `.read()`/`.write()` calls from Lumen code (every
prior use of `std.Io.Reader`/`Writer` in this codebase -- `http`'s server,
the playground's own compile service -- has the reader/writer's backing
buffer live as a short-lived stack local for the duration of one function
call; a `Stream` object handed back to the *caller* needs that buffer to
outlive the call that created it, a new requirement none of the existing
code has needed).

A file's reader/writer and a network connection's reader/writer are
different concrete types in this Zig version (no common "any byte source"
interface below `std.Io.Reader` itself that both trivially convert to
without extra plumbing). Rather than design the file case and the network
case at the same time and risk getting the shared shape wrong, this spec
does the file case first -- it's the one with an existing, concrete,
already-named blocker (`fs.createReadStream`), and validates the
`LumenReadableStream`/`WritableStream`-as-built-in-type approach before
extending it to a second, more complex backing source.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `fs.createReadStream(path)` | `string -> ReadableStream` | opens `path` for reading; nothing is read until `.read()` is called |
| `fs.createWriteStream(path)` | `string -> WritableStream` | opens/truncates `path` for writing |

| Method | Type | Notes |
| --- | --- | --- |
| `ReadableStream.read()` | `() -> string` | the next chunk (bounded by a fixed internal buffer, e.g. 64KB); empty string at EOF |
| `ReadableStream.close()` | `() -> void` | closes the underlying file; safe to call after EOF or early |
| `WritableStream.write(chunk)` | `string -> void` | appends `chunk` to the file |
| `WritableStream.close()` | `() -> void` | flushes any buffered bytes, then closes |

## Design notes

- **Architecture**: `ReadableStream`/`WritableStream` are built-in types
  following `Map`/`Set`/`EventEmitter<T>`'s exact pattern -- dedicated
  `types.Type` variants (`.readable_stream_type`/`.writable_stream_type`),
  special-cased in `new_expr`-adjacent construction checking (via
  `fs.createReadStream`/`createWriteStream` rather than a `new` expression,
  since these are always created by opening a real file, not constructed
  empty), with method dispatch mirroring `mapMethod`/`setMethod`/
  `eventEmitterMethod`. Not generic (no type parameter): every chunk is
  `string`, matching every other body/chunk of data this whole session's
  `fs`/`http`/`process` work already represents as `string`.
- **`.read()` returning `""` for EOF, not a distinguishable "no more
  data" signal**: matches how a truly empty chunk and end-of-stream are
  indistinguishable here -- a real, minor simplification. Node
  distinguishes "stream ended" from "an empty chunk arrived" via separate
  events; this collapses them, acceptable because a zero-byte chunk in
  the middle of a stream is not a case any of `fs`'s current writers
  (`writeFileSync`, `appendFileSync`, the async trio) produce today.
- **No backpressure, no async integration**: `.read()`/`.write()` are
  synchronous, blocking calls (matching `fs.readFileSync`'s blocking
  model, not the async event-loop-driven `fs.readFile`). A caller loops
  calling `.read()` until it gets `""`. This is simpler and more
  predictable than trying to integrate with the async runtime in the same
  pass that introduces the type itself.
- **Chunk size is fixed, not caller-configurable**: one internal buffer
  size for all streams (64KB, matching the async `fs.readFile`'s existing
  chunk size for consistency), not exposed as a parameter. Simpler API
  surface for v1; straightforward to add a size parameter later without
  breaking the existing no-argument calls.
- **Works under `--wasm` the same way `fs.readFileSync` already does, no
  `target-wasm-limited` tag needed**: confirmed by actually running the
  compiled wasm module (not just compile-checking it). The first attempt
  used an absolute path and produced wrong results (0 bytes read) --
  investigated rather than written off as broken, and turned out to be a
  WASI preopen/absolute-path resolution quirk unrelated to this feature: a
  relative path with matching directory access produced byte-identical
  output to the native run. File-backed streams don't touch anything
  fundamentally incompatible with the wasm sandbox the way
  `http`/`child_process`/`fs.watch` do.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Network-backed streams (`http` request/response bodies, `child_process` stdio) | a second concrete backing type (`std.Io.net.Stream`'s reader/writer, distinct from a file's); this spec validates the file-backed shape first, see "Why file-backed only" above |
| Async/event-loop-integrated streaming (non-blocking `.read()`, backpressure, a `'data'`/`'end'`-event shape like Node's real streams) | `.read()`/`.write()` here are synchronous/blocking; real async integration is a separate, later feature |
| Piping (`readable.pipe(writable)`) | a real, separate convenience feature on top of the two primitives this spec ships |
| Caller-configurable chunk size | fixed at 64KB for v1, see design notes |
| Streaming transforms (gzip, encoding conversion) | needs the piping/transform-stream concept above first |
