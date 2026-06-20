# Tasks — Spec 101 Buffer

- [x] T1. `host_buffer.zig` (new): `Enc` + codecs (utf8 passthrough, hex, base64 via `std.base64`,
      latin1/ascii via codepoint↔byte, utf16le BMP) — `encode`/`decode`; plus all native impls.
- [x] T2. `NativeId.buffer_fn` (one id, dispatch by name) + the second-switch unreachable arm.
- [x] T3/T4. `host_buffer.installBuffer` builds `Buffer` (function) + `Buffer.prototype`
      (proto=`%Uint8Array.prototype%`); statics alloc/allocUnsafe(Slow)/from/isBuffer/byteLength/concat;
      methods toString/write/slice/subarray/equals/toJSON + UInt8/UInt16LE·BE/UInt32LE·BE read+write.
      Instances = `Object.createTypedArray(.u8)` over a fresh `createArrayBuffer`, reproto'd to
      `Buffer.prototype`; bytes read/written via `bytesOf` (the backing ArrayBuffer slice). slice/subarray
      share memory (new view over the same buffer). Called from `host_setup.installHostGlobals`.
- [x] T5. `interp_native.zig`: dispatch `.buffer_fn` (with `this_val` for prototype methods).
- [x] T6. Verified: length/index, toString utf8/hex/base64, alloc, from(array), isBuffer, concat,
      slice-shares-memory (`axcd`), writeUInt16LE/readUInt16LE·BE, writeUInt32BE/readUInt32BE,
      `instanceof Uint8Array`, byteLength (multi-byte), toJSON.
- [x] T7. build/test/lint/bench GREEN; language conformance: ok (42,308/95.1%, 0 regressions); Buffer host-only. Committed + pushed.
