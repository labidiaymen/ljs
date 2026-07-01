# Spec 035: crypto API

## Goal

A practical subset of Node's `crypto` module: `crypto.randomBytes(n)`,
`crypto.randomUUID()`, `crypto.sha256(data)`. Picked as the next stdlib target
over the alternative (`child_process`) because every one of these is pure
computation with no syscalls involved, so it works identically on the native
and WebAssembly targets with none of the "guard this for wasm" work `os` and
`process.pid()` needed.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `crypto.randomBytes(n)` | `int -> string` | `n` random bytes, hex-encoded (a `2n`-character string). No `Buffer` type in the language yet, so this returns the encoded form directly rather than a byte buffer you'd call `.toString('hex')` on yourself |
| `crypto.randomUUID()` | `() -> string` | a v4 UUID (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`), from 16 random bytes with the version/variant bits set per RFC 4122 |
| `crypto.sha256(data)` | `string -> string` | hex digest of the SHA-256 hash of `data`'s bytes |

All three are namespace-static function calls, matching every other stdlib
module (`Math.abs`, `path.join`, `os.platform`) rather than Node's
`crypto.createHash(...).update(...).digest(...)` fluent/stateful style --
Lumen has no built-in streaming-hash object, and a one-shot function covers
the overwhelming majority of real use (tokens, UUIDs, content hashing).

## Design notes

- **Randomness source**: the runtime's `Io` abstraction exposes `random`/
  `randomSecure` directly (confirmed as a real, working primitive across
  every backend checked, not a stub -- Windows goes through the CNG device,
  other targets through their own secure source, with a documented
  best-effort fallback only if no entropy source exists at all). `randomBytes`
  and `randomUUID` both go through this, not anything from `std.crypto`
  itself (which has hashing/AEAD/etc. but no convenience global RNG in this
  version).
- **Hex encoding**: manual byte-to-hex-nibble loop, not a fixed-length
  formatter -- `n` is a runtime value, and the available fixed-length hex
  helper needs a comptime-known input length.
- **`sha256`**: one-shot `Sha256.hash(data, &out, .{})`, then the same hex
  encoding as above. `md5`/`sha1` are available from the same source if a
  legacy-hash need comes up later; not included in v1 since `sha256` covers
  the common case and there's no reason to reach for a weaker default.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `crypto.createHash(algo)` streaming API | a stateful hash-builder object; the language has no built-in equivalent to reach for yet, and one-shot `sha256(data)` covers the common case |
| `crypto.createHmac`, `crypto.sign`/`verify`, `crypto.publicEncrypt`/etc. | asymmetric/keyed crypto is a much larger surface than this milestone's scope |
| `crypto.pbkdf2`/`scrypt` (password hashing) | real feature, deliberately deferred rather than rushed; picking the right default cost parameters matters and deserves its own pass |
| `md5`/`sha1` as named functions | available from the same source as `sha256` if needed later, left out of v1 to avoid presenting a weak hash as a first-class option next to `sha256` |
