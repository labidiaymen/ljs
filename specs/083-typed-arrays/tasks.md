# Tasks 083 — Typed Arrays

## Phase 1 — Foundation (sequential, one agent; lands + gates before Phase 2)
- [x] T1.1 Add object kinds `array_buffer`, `typed_array`, `data_view` + backing structs
  (`ArrayBufferData`, `TypedArrayData`, `DataViewData`) to `src/object.zig`; allocator-owned bytes,
  freed on collection (no leak under testing allocator).
- [x] T1.2 `ElemType` enum (11 types) + element codecs `getElement`/`setElement` (signedness, Uint8
  clamping, float encode/decode, bigint content type) in `src/typed_array.zig` (new) or `runtime_types.zig`.
- [x] T1.3 Integer-indexed exotic get/set in `src/interp_property.zig` (§10.4.5 + §6.1.7
  CanonicalNumericIndexString): in-bounds codec, OOB read→undefined, invalid write→no-op, no string
  own keys; guarded so the non-typed-array hot path is unchanged.
- [x] T1.4 Minimal `src/builtin_arraybuffer.zig`: `new ArrayBuffer(len)` + `byteLength` getter; register
  in `src/builtins.zig`. Stub-register `TypedArray`/`DataView` globals.
- [x] T1.5 GATE: `zig build`/`test`/`lint` green, `zig build bench` `perf: ok` (re-bench vs pre-foundation
  HEAD), `language/` 0-regression. Commit + integrate to main. (commit 263b924)

## Phase 2 — Views (parallel, 3 agents against the fixed foundation; integrate sequentially)
### 2-A ArrayBuffer (full) — `src/builtin_arraybuffer.zig`
- [x] T2A.1 `ArrayBuffer.prototype.slice` (species-aware), `ArrayBuffer.isView`, `Symbol.species`,
  `[Symbol.toStringTag]`, detached-state checks.
- [x] T2A.2 Resizable: `maxByteLength` option, `resizable`, `resize`, `maxByteLength` getter.
- [x] T2A.3 GATE + integrate. (`transfer`/`transferToImmutable` deferred to a follow-up.)

### 2-B TypedArray (×11 + %TypedArray%) — `src/builtin_typedarray.zig`
- [x] T2B.1 `%TypedArray%` abstract super + the 11 concrete constructors; `BYTES_PER_ELEMENT`
  (instance + ctor); reject `%TypedArray%()` direct construction.
- [x] T2B.2 Construction overloads: length / typed-array / arraybuffer(+offset,+len) / array-like+iterable.
- [x] T2B.3 Getters `buffer`/`byteLength`/`byteOffset`/`length`/`[Symbol.toStringTag]`.
- [x] T2B.4 Prototype methods (37 — at, copyWithin, entries, every, fill, filter, find*, forEach, includes,
  indexOf, join, keys, lastIndexOf, map, reduce, reduceRight, reverse, set, slice, some, sort,
  subarray, toLocaleString, toReversed, toSorted, values, with, `[Symbol.iterator]`, toString).
- [x] T2B.5 Statics `from`/`of` + `Symbol.species`.
- [x] T2B.6 GATE + integrate.

### 2-C DataView — `src/builtin_dataview.zig`
- [x] T2C.1 `new DataView(buffer, byteOffset, byteLength)` + `buffer`/`byteLength`/`byteOffset` getters +
  `[Symbol.toStringTag]`.
- [x] T2C.2 `getInt8/Uint8/Int16/Uint16/Int32/Uint32/Float32/Float64/BigInt64/BigUint64` + matching
  `setXxx` with `littleEndian` flag, bounds + detached-buffer TypeErrors.
- [x] T2C.3 GATE + integrate.

## Integration
- [x] Cherry-picked 2-A/2-B/2-C onto main, resolved the additive wiring conflicts (interp_native/interp_expr/builtins).
- [x] FIX: the combined build exposed a panic — a resizable ArrayBuffer shrunk below a typed array's
  stored `array_length`, so the element codec read past the live slice. Added a §10.4.5 bounds guard in
  `typed_array.zig` `getElement`/`setElement` (OOB read→undefined, write→no-op). Caught only by the
  full combined `built-ins/` + `language/` run, not the agents' isolated worktree gates.

## Close
- [x] T3 Final full `built-ins/` + `language/` run (0 panics): built-ins 45.0%→53.2% (+3,856),
  language held at 40,450. Recorded the delta in spec.md Status; updated `baseline/builtins.json` to
  the new passing set; committed spec + code.
