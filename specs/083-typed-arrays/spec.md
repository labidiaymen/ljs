# Spec 083 — Typed Arrays: ArrayBuffer, TypedArray (×11), DataView

**Status:** Done — `built-ins/` 45.0% → **53.2%** (21,155 → **25,011**, **+3,856**); `language/` held at
40,450 (0 regressions). ArrayBuffer 58→184/442, TypedArray 1934/2876, DataView 628/1122. Integration
caught + fixed a family of resizable-buffer-shrink panics (codec / copyWithin / slice / byteOffset /
DataView revalidation) the agents' isolated runs missed. Deferred: `ArrayBuffer.prototype.transfer*`,
length-tracking auto-resize, `Float16`, `SharedArrayBuffer`/`Atomics`.
**Governing clauses:** ECMA-262 §25.1 (ArrayBuffer), §23.2 (TypedArray objects + %TypedArray%
intrinsic), §25.3 (DataView), §10.4.5 (Integer-Indexed exotic objects), §6.1.7 (CanonicalNumericIndexString).

## Goal
Implement the binary/typed-array stack: `ArrayBuffer` (the raw byte backing store), the 11 concrete
TypedArray constructors viewing into a buffer, and `DataView` for explicit-endianness access. This
is the largest single remaining `built-ins/` pool that is **pure ECMAScript** (in charter) and is the
prerequisite for any future binary I/O (e.g. a Node `Buffer`).

## In scope
- **ArrayBuffer (§25.1):** `new ArrayBuffer(len)`, `byteLength` getter, `ArrayBuffer.prototype.slice`,
  `ArrayBuffer.isView`, `Symbol.species`, `[Symbol.toStringTag]`, detachment state. Resizable
  buffers (`maxByteLength` option, `resizable`/`resize`/`maxByteLength`) IF cheap; else deferred.
- **TypedArray (§23.2):** the 11 element types — `Int8Array`, `Uint8Array`, `Uint8ClampedArray`,
  `Int16Array`, `Uint16Array`, `Int32Array`, `Uint32Array`, `Float32Array`, `Float64Array`,
  `BigInt64Array`, `BigUint64Array` — over the shared `%TypedArray%` abstract super.
  - Construction: from length, from another typed array, from an ArrayBuffer (+byteOffset, +length),
    from an array-like / iterable. `BYTES_PER_ELEMENT` (instance + constructor).
  - Integer-indexed element **get/set** with §10.4.5 CanonicalNumericIndexString semantics
    (out-of-bounds reads → `undefined`, writes are dropped; no own enumerable string keys).
  - Getters: `buffer`, `byteLength`, `byteOffset`, `length`, `[Symbol.toStringTag]`.
  - `%TypedArray%.prototype` methods: `at`, `copyWithin`, `entries`, `every`, `fill`, `filter`,
    `find`, `findIndex`, `findLast`, `findLastIndex`, `forEach`, `includes`, `indexOf`, `join`,
    `keys`, `lastIndexOf`, `map`, `reduce`, `reduceRight`, `reverse`, `set`, `slice`, `some`,
    `sort`, `subarray`, `toLocaleString`, `toReversed`, `toSorted`, `values`, `with`,
    `[Symbol.iterator]`, `toString` (= Array's).
  - Statics on `%TypedArray%`: `from`, `of`, `Symbol.species`.
- **DataView (§25.3):** `new DataView(buffer, byteOffset, byteLength)`, `buffer`/`byteLength`/
  `byteOffset` getters, `getInt8/Uint8/Int16/Uint16/Int32/Uint32/Float32/Float64/BigInt64/BigUint64`
  and the matching `setXxx`, each honouring the `littleEndian` flag, `[Symbol.toStringTag]`.

## Out of scope
- `SharedArrayBuffer` and `Atomics` (a separate concurrency engine — own milestone).
- `Float16Array` / `getFloat16`/`setFloat16` (defer unless trivial).
- Node `Buffer` (host API, out of charter).

## User scenarios (Given/When/Then, derived from Test262 `built-ins/{ArrayBuffer,TypedArray*,DataView}`)
- **Given** `new Uint8Array(4)` **When** I write `a[0]=255; a[1]=256` **Then** `a[0]===255`,
  `a[1]===0` (wraparound), `a.length===4`, `a.byteLength===4`.
- **Given** `new Int32Array([1,2,3])` **When** I read `.byteLength` **Then** it is `12`
  (`3 * BYTES_PER_ELEMENT`), and `Int32Array.BYTES_PER_ELEMENT===4`.
- **Given** an `ArrayBuffer(8)` and `new Float64Array(buf)` **When** I check `.length` **Then** `1`,
  and the typed array shares storage with the buffer (writes are visible via a `DataView` on `buf`).
- **Given** `new DataView(buf)` **When** `dv.setUint16(0, 0x1234, true); dv.getUint16(0, false)`
  **Then** `0x3412` (endianness honoured).
- **Given** `new Uint8Array([3,1,2])` **When** `.sort()` **Then** `Uint8Array(3) [1,2,3]` (numeric,
  not lexicographic) and the result is the same instance.
- **Given** a detached buffer **When** any indexed access or view method runs **Then** a `TypeError`
  (or `undefined`/no-op per the clause), never a crash.
- **Given** `a[-1]` or `a["1.5"]` or `a[5]` on a length-4 array **Then** read → `undefined`, write →
  silently ignored (canonical-numeric-index rules), never an own property.

## Success criteria
- Measurable `built-ins/` conformance increase across `ArrayBuffer`, `TypedArray*`, `TypedArrayConstructors`
  and `DataView` partitions (target: the bulk of these partitions pass; record the exact delta at the gate).
- **Zero** `language/` regression (`baseline/language.json`, passed stays ≥ 40,414).
- `built-ins/` baseline updated to the new passing set only at milestone close (never per-cycle).
- `zig build` / `test` / `lint` green; `zig build bench` `perf: ok` (typed arrays add a new object kind
  on the property-access hot path — must not regress the non-typed-array fast path).
