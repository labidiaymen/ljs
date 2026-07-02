# Tasks: Streams (file-backed)

## Phase 1

- [x] T1 Added `.readable_stream_type`/`.writable_stream_type` to the
  `Type` union. Used the compiler's own exhaustive-switch errors to find
  every spot needing a matching arm (`same`/`mangle`/`zigName`/
  `toAnnotation`), the same way spec 043's `EventEmitter` addition did.
  Neither carries a payload (not generic -- every chunk is `string`).
- [x] T2 `fs.createReadStream(path)`/`createWriteStream(path)` -- checker
  branches in `fsCallType`, opening the file synchronously (reusing the
  same `std.Io.Dir.cwd().openFile`/`createFile` calls
  `fs.readFileSync`/`writeFileSync` already use) and wrapping the result
  in the new stream type.
- [x] T3 Runtime `LumenReadableStream`/`LumenWritableStream`: each owns
  an `?std.Io.File` (`null` for a missing/unopenable file -- degrades to
  a stream that always reads `""`/no-ops `.close()`, the same "fallback,
  don't crash" shape every other `fs` function uses) plus a
  heap-allocated buffer (via `__sa()`, the stable arena `Map`/`Set`/
  `EventEmitter` already use) and the `std.Io.File.Reader`/`Writer`
  wrapper, via `readerStreaming`/`writerStreaming`. `.read()` uses
  `readSliceShort` (confirmed the right primitive: reads up to N bytes,
  returns the actual count, short reads at EOF) into a scratch buffer,
  then copies the result into a fresh, stable allocation -- returning a
  slice into the reused scratch buffer directly would have gotten
  clobbered by the next `.read()` call.
- [x] T4 Method dispatch: `readableStreamMethod`/`writableStreamMethod`
  in `lumen_check_stdlib.zig`, mirroring `mapMethod`/`setMethod`/
  `eventEmitterMethod`'s exact structure (`mc.container_type = obj_type`
  sentinel, so the existing generic method-call emit code handles
  codegen with zero `lumen_emit.zig` changes needed for the methods
  themselves -- only the `fs.createReadStream`/`createWriteStream`
  *construction* calls needed a new emit branch).
- [x] T5 Verified with a real, sizeable file (100,000 bytes, deliberately
  larger than the 64KB chunk size to force multiple `.read()` calls, not
  a single-chunk file that would pass even with a broken loop): the
  reassembled content's length matched exactly, `fs.readFileSync`'s
  whole-file read of the same file matched byte-for-byte, and multiple
  `.read()` calls were confirmed to have actually happened (not just
  one). A write via 10,000 separate `.write()` calls followed by a
  `.close()` produced a file whose content, read back, matched exactly.
  A `fs.createReadStream` on a nonexistent file returned `""` from
  `.read()` and didn't crash on `.close()`.
- [x] T6 Confirmed `--wasm` compiles and runs correctly (via wasmtime,
  not just compile-checked). First test used an absolute path
  (`/tmp/...`) and got wrong results (`0` bytes read) -- investigated
  rather than assumed broken: this turned out to be a WASI preopen/
  absolute-path quirk, not a real bug in the streams implementation. A
  relative path with matching `--dir` access produced byte-identical
  output to the native run. No `target-wasm-limited` tag needed --
  file-backed streams work under wasm the same way `fs.readFileSync`
  already does, unlike `http`/`child_process`/`fs.watch`, which are
  fundamentally incompatible with the wasm sandbox.
- [x] T7 `zig build test` passes. `zig build conformance` run clean.
- [x] T8 Updated `website/stdlib.html`: added to the existing `fs`
  section (the same treatment `fs.watch` got).
- [x] T9 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: network-backed streams (the reason
this exists in the first place, per the http-streaming motivation --
explicit, deliberate follow-up, not forgotten), async/backpressure
integration, piping, configurable chunk size, streaming transforms.
