# Tasks: Streams (file-backed)

## Phase 1

- [ ] T1 Add `.readable_stream_type`/`.writable_stream_type` to the
  `Type` union in `lumen_types.zig`. Follow the compiler's own guidance
  (adding a variant makes the exhaustive `same`/`mangle`/`zigName`/
  `toAnnotation` switches fail to compile until handled -- use those
  errors to find every spot, the same way spec 043's `EventEmitter`
  addition did) rather than manually hunting for every switch by hand.
- [ ] T2 `fs.createReadStream(path)`/`createWriteStream(path)` --
  checker branches in `fsCallType`, opening the file synchronously
  (reusing the same `std.Io.Dir.cwd().openFile`/`createFile` calls
  `fs.readFileSync`/`writeFileSync` already use) and wrapping the result
  in the new stream type.
- [ ] T3 Runtime `LumenReadableStream`/`LumenWritableStream`: each owns
  its `std.Io.File`, a heap-allocated read/write buffer (via `__sa()`,
  the same stable arena `Map`/`Set`/`EventEmitter` use), and the
  `std.Io.File.Reader`/`Writer` wrapper. `.read()` via
  `readSliceShort`-style bounded reads (confirmed this is the right
  primitive: reads up to N bytes, returns the actual count, short reads
  at EOF -- not a full-buffer-or-error read). `.write()`/`.close()`
  straightforward.
- [ ] T4 Method dispatch: `readableStreamMethod`/`writableStreamMethod`
  in `lumen_check_stdlib.zig`, mirroring `mapMethod`/`setMethod`/
  `eventEmitterMethod`'s exact structure (`mc.container_type = obj_type`
  sentinel, so the existing generic method-call emit code handles
  codegen with no `lumen_emit.zig` changes needed, the same "free"
  dispatch `EventEmitter`'s methods got).
- [ ] T5 Verify with a real, sizeable file (larger than one chunk, to
  actually exercise multiple `.read()` calls, not just a single-chunk
  file that would pass even with a broken loop): read it back via
  repeated `.read()` calls until `""`, confirm the reassembled content
  matches exactly (byte for byte, via a checksum or direct comparison
  against `fs.readFileSync`'s whole-file read of the same file); write a
  file via multiple `.write()` calls, confirm the final file's content
  via `fs.readFileSync` matches what was written; confirm `.close()`
  before EOF doesn't crash or corrupt anything.
- [ ] T6 `zig build test` passes. `zig build conformance` run clean.
- [ ] T7 Update `website/stdlib.html`: add to the existing `fs` section,
  not a new top-level module (same treatment `fs.watch` got).
- [ ] T8 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: network-backed streams (the reason
this exists in the first place, per the http-streaming motivation --
explicit, deliberate follow-up, not forgotten), async/backpressure
integration, piping, configurable chunk size, streaming transforms.
