# Spec 101 — `Buffer` (Node binary data) — Node axis, slice 4

Status: In progress
Owner: Aymen

## Context
Slices 1–3 (specs 098–100) gave the event loop, scheduling, and `process`/`global`. Slice 4 adds
**`Buffer`** — Node's binary-data type — as a host global (installed via `host_setup`, NOT on the
Test262 path). `Buffer` is a `Uint8Array` subclass in Node; ljs already has `Uint8Array`
(typed arrays, specs 083/084), so back `Buffer` by the existing typed-array machinery where possible.

This is a **first cut** — the most-used surface — with the long tail deferred (see Out of scope).

## Surface (slice 4)
A `Buffer` global (a function object) + `Buffer.prototype` whose `[[Prototype]]` is
`Uint8Array.prototype` (so length/indexing/iteration/`Symbol.iterator` come for free), with:

**Statics:**
- `Buffer.alloc(size[, fill[, encoding]])` — zero-filled (or `fill`-filled) buffer of `size` bytes.
- `Buffer.allocUnsafe(size)` / `Buffer.allocUnsafeSlow(size)` — uninitialized-semantics (we zero-fill).
- `Buffer.from(string[, encoding])` — encode the string (`utf8` default, `hex`, `base64`, `latin1`,
  `ascii`, `utf16le`/`ucs2`).
- `Buffer.from(array)` — bytes from an array of numbers (mod 256).
- `Buffer.from(arrayBuffer[, byteOffset[, length]])` — a view sharing the ArrayBuffer.
- `Buffer.from(buffer)` — copy of another buffer/Uint8Array.
- `Buffer.isBuffer(obj)`, `Buffer.byteLength(string[, encoding])`, `Buffer.concat(list[, totalLength])`.

**Prototype (beyond the inherited Uint8Array methods):**
- `buf.toString([encoding[, start[, end]]])` — decode (utf8/hex/base64/latin1/ascii/utf16le).
- `buf.write(string[, offset[, length]][, encoding])` — encode into the buffer; returns bytes written.
- `buf.slice([start[, end]])` / `buf.subarray(...)` — a VIEW sharing memory (Node `slice` shares,
  unlike `Array.prototype.slice`).
- `buf.equals(other)`, `buf.toJSON()` (`{ type: "Buffer", data: [...] }`).
- `buf.readUInt8`/`writeUInt8`/`readUInt16LE`/`readUInt32LE`/… — a SMALL representative set (the full
  read/write matrix is deferred; include at least UInt8 + UInt16LE/BE + UInt32LE/BE).

The instances must be real byte-backed typed arrays (so `buf[i]`, `buf.length`, `for..of`, spread,
and the inherited TypedArray methods work). Implementation: create a `Uint8Array` over a fresh
`ArrayBuffer`, then set its `[[Prototype]]` to `Buffer.prototype`. Encodings live in a
`host_buffer.zig` (hex/base64/utf16le codecs, pure std `std.base64`).

## Acceptance
- `Buffer.from("hi").length === 2`, `Buffer.from("hi")[0] === 104`.
- `Buffer.from("hello").toString() === "hello"`; `Buffer.from("hi").toString("hex") === "6869"`.
- `Buffer.from("aGk=", "base64").toString() === "hi"`; `Buffer.alloc(3).toString("hex") === "000000"`.
- `Buffer.from([1,2,3]).toString("hex") === "010203"`; `Buffer.isBuffer(Buffer.alloc(1)) === true`.
- `Buffer.concat([Buffer.from("ab"), Buffer.from("cd")]).toString() === "abcd"`.
- `Buffer.from("abcd").slice(1,3).toString() === "bc"` (and slice SHARES memory: mutating the slice
  mutates the parent).
- `b.writeUInt16LE(0x1234,0); b.readUInt16LE(0) === 0x1234`.
- `Buffer.from("hi") instanceof Uint8Array === true`.
- **Regression:** `Buffer` installs host-only; `language/` + `built-ins/` 0 regressions;
  build/test/lint/bench green.

## Out of scope (later)
- The full read/write numeric matrix (Int*, BE/LE all widths, BigInt64, Float/Double, `*offset`
  variants), `indexOf`/`includes`/`fill`/`copy`/`compare`/`swap16/32/64`, `Buffer.compare`,
  `transcode`, the `buffer` module / `Blob`, pooling semantics, `latin1` vs `binary` nuances beyond
  the basics. `TextEncoder`/`TextDecoder` (separate WHATWG slice).
