# Spec 084 — Typed-array tail: ArrayBuffer transfer + length-tracking views

**Status:** Done — `built-ins/` 53.2% → **53.4%** (25,011 → **25,111**, **+100**); `language/` held at
40,450 (0 regressions, EXIT 0). Full built-ins sweep: panics 0, EXIT 0. Extends spec 083 (the
typed-array stack): the two deferred pieces — `ArrayBuffer.prototype.transfer` / `transferToImmutable`
and auto-length (length-tracking) views over a resizable ArrayBuffer.
**Governing clauses:** ECMA-262 §25.1.6 (`transfer` / `transferToImmutable`, immutable buffers),
§23.2 / §10.4.5 (Integer-Indexed exotic objects — auto-length `[[ArrayLength]]`), §25.3
(DataView auto-length).

## Goal
Close the two tail items from spec 083:
1. **`ArrayBuffer.prototype.transfer(newLength?)` / `transferToImmutable()` (§25.1.6.x).** Move the
   backing data into a fresh buffer (resizable iff the source was, carrying `maxByteLength`),
   detaching the source. `transferToImmutable` produces a fixed-length, IMMUTABLE buffer; `resize`
   and `transfer` on an immutable buffer throw a TypeError.
2. **Length-tracking views (§23.2 / §10.4.5 / §25.3 auto-length).** A TypedArray or DataView created
   over a RESIZABLE ArrayBuffer with NO explicit length argument tracks the buffer's live length:
   growing the buffer makes the view longer, shrinking makes it shorter. Explicit-length views stay
   fixed (and read out-of-bounds when the buffer shrinks below them — already crash-safe).

## In scope
- `ArrayBuffer.prototype.transfer` (length 0, default newLength = source byteLength).
- `ArrayBuffer.prototype.transferToImmutable` (length 0).
- An `immutable` flag on `ArrayBufferData`; `resize` / `transfer` on an immutable buffer → TypeError.
- A `tracks_length` flag on `TypedArrayData` and `DataViewData`, set at construction when the view is
  over a resizable buffer with no explicit length.
- A single `liveLength` helper routing ALL length reads (TA.of, the length/byteLength getters, the
  method dispatcher `len`, and the `typedArrayGet`/`typedArraySet` bounds).

## Out of scope
- `SharedArrayBuffer` / growable shared buffers (separate concurrency milestone).
- `Float16Array` / `Atomics`.
- `ArrayBuffer.prototype.transfer` species nuance (the spec creates a plain %ArrayBuffer%, no species).

## User scenarios (Given/When/Then)
- **Given** `const a = new ArrayBuffer(8); const b = a.transfer()` **Then** `b.byteLength === 8`,
  `a.detached === true`, `a.byteLength === 0`, and the bytes moved to `b`.
- **Given** `new ArrayBuffer(4).transfer(8)` **Then** the result is `byteLength 8` with the low 4
  bytes copied and the upper 4 zero-filled.
- **Given** `new ArrayBuffer(8).transfer(4)` **Then** `byteLength 4` (truncated copy).
- **Given** a resizable `new ArrayBuffer(8, {maxByteLength: 16})` **When** `.transfer()` **Then** the
  result is resizable with `maxByteLength === 16`.
- **Given** `const b = a.transferToImmutable()` **Then** `b.resize` / `b.transfer` throw TypeError,
  `b.maxByteLength === b.byteLength`, `b.resizable === false`, and `a` is detached.
- **Given** a detached buffer **When** `.transfer()` / `.transferToImmutable()` **Then** TypeError.
- **Given** `const rab = new ArrayBuffer(8, {maxByteLength: 16}); const ta = new Uint8Array(rab)`
  (no length) **When** `rab.resize(16)` **Then** `ta.length === 16`; **When** `rab.resize(4)` **Then**
  `ta.length === 4` and `ta[7] === undefined`.
- **Given** `new Uint8Array(rab, 0, 8)` (EXPLICIT length 8) **When** `rab.resize(4)` **Then** the view
  is out of bounds: `ta.length === 0` (already crash-safe), and reads yield `undefined`.
- **Given** `new DataView(rab)` (no length) **When** `rab.resize(N)` **Then** `dv.byteLength === N`.

## Success criteria
- `language/` holds at baseline (passed ≥ 40,450, no regression, EXIT 0).
- `built-ins/` typed-array pools improve (ArrayBuffer transfer + resizable-length tests now pass);
  the FULL built-ins sweep reports `panics: 0` and EXIT 0.
- No bench regression (length-tracking is the only path that recomputes; the fixed-view fast path is
  unchanged).
