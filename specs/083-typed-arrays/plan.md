# Plan 083 — Typed Arrays

## Approach: foundation first (sequential), then fan out the three views (parallel)
The three surfaces share a data model and the interpreter's indexed-access path, both of which live
in single-owner core files. So Phase 1 lands the foundation; Phase 2 fans out one agent per view file.

### Phase 1 — Foundation (ONE agent, sequential, must land + gate before Phase 2)
Files: `src/object.zig`, `src/runtime_types.zig`, `src/interp_property.zig`, a new
`src/builtin_arraybuffer.zig` (minimal), wiring in `src/builtins.zig`.
- **Object kinds + slots** (`object.zig`): add object kinds `array_buffer`, `typed_array`, `data_view`
  and their backing structs:
  - `ArrayBufferData { bytes: []u8, detached: bool, max_byte_length: ?usize }` (arena/allocator owned).
  - `TypedArrayData { buffer: *Object, byte_offset, array_length, elem: ElemType, content_type }`
    where `ElemType` is an enum over the 11 types carrying `bytes_per_element` + a read/write codec.
  - `DataViewData { buffer: *Object, byte_offset, byte_length }`.
- **Element codecs** (`runtime_types.zig` or a new `src/typed_array.zig`): pure functions
  `getElement(elem, bytes, idx) -> Value` and `setElement(elem, bytes, idx, Value) -> void` covering
  signedness, clamping (Uint8Clamped), float encode/decode, and BigInt content type. Endianness for
  TypedArray element access is platform native per spec (DataView takes an explicit flag).
- **Integer-indexed exotic get/set** (`interp_property.zig`): in the property get/set dispatch, when
  the object kind is `typed_array`, route a CanonicalNumericIndexString key through
  IntegerIndexedElementGet/Set (§10.4.5): in-bounds → codec; OOB read → `undefined`; OOB/invalid write
  → no-op; never falls through to ordinary string-keyed storage. Guard so the NON-typed-array path is
  untouched (a single `kind == .typed_array` branch, off the hot path otherwise).
- **Minimal `builtin_arraybuffer.zig`**: `new ArrayBuffer(len)` + `byteLength` getter so the foundation
  compiles and a smoke test (`new Uint8Array(new ArrayBuffer(8)).length === 8`) passes after Phase 2-B,
  and a couple of ArrayBuffer tests pass now.
- Register the new globals as stubs in `builtins.zig` (constructors wired in Phase 2).

### Phase 2 — Views (THREE agents in parallel, each owns ONE new file, against the fixed foundation)
- **2-A `builtin_arraybuffer.zig` (full):** `slice`, `isView`, `Symbol.species`, toStringTag, detach
  semantics; resizable (`maxByteLength`/`resize`) if cheap.
- **2-B `builtin_typedarray.zig`:** the 11 concrete constructors + `%TypedArray%` abstract super; the
  4 construction overloads; `BYTES_PER_ELEMENT`; all prototype methods (reuse Array's algorithms where
  the spec text matches, but with typed get/set and species-create); `from`/`of`; iteration; toStringTag.
- **2-C `builtin_dataview.zig`:** constructor + the 9 `getXxx`/`setXxx` pairs with the `littleEndian`
  flag, bounds checks, detached-buffer TypeErrors.

Integration: cherry-pick/merge each onto main sequentially, `zig build`/`test`/`lint`/`bench` +
conformance gate after each. Renumber if any milestone-number collision.

## Design calls
- **Shared backing store:** `TypedArrayData.buffer` and `DataViewData.buffer` point at the SAME
  `*Object` ArrayBuffer; element access indexes `buffer.array_buffer.bytes[byte_offset + i*bpe ..]`.
  This gives correct aliasing (a write through a typed array is visible through a DataView) for free.
- **ElemType as a tagged enum with a jump table**, not 11 separate structs — keeps the prototype
  methods generic (one `set`/`slice`/`sort` body parameterised by `elem`).
- **Content type (number vs bigint):** BigInt64/BigUint64 are `content_type = bigint`; mixing a bigint
  typed array with a number (or vice versa) in `set`/element-write throws per §23.2.

## Constitution check
- **Correctness leads:** every method cites its §23.2/§25.1/§25.3 clause; behavior validated by Test262,
  not intuition. Detached-buffer and OOB paths return the spec result, never crash.
- **Perf no-regression gate:** the only hot-path change is one `kind == .typed_array` branch in indexed
  get/set; `zig build bench` must stay `perf: ok`. Re-bench after Phase 1.
- **No leaks** under the testing allocator (ArrayBuffer bytes are allocator-owned, freed on collection).
