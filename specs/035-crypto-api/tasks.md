# Tasks: crypto API

## Phase 1

- [x] T1 Added `"crypto"` to the parser's `isStdNamespace` list. New
  `cryptoCallType` in `lumen_check_stdlib.zig` (mirrors `osCallType`), wired
  into `staticCallType`.
- [x] T2 `crypto.randomBytes(n)` -- `int -> string`, hex-encoded. Uses
  `std.Io.random(io, buf)`, confirmed a real, working, cross-platform
  primitive (not a stub) by reading the backend directly.
- [x] T3 `crypto.randomUUID()` -- `() -> string`, v4 UUID from 16 random
  bytes with version/variant bits set per RFC 4122.
- [x] T4 `crypto.sha256(data)` -- `string -> string`, hex digest via
  `std.crypto.hash.sha2.Sha256.hash`.
- [x] T5 Verified: one program exercises all three. `sha256("hello")`
  matched Python's `hashlib.sha256` exactly
  (`2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824`).
  `randomBytes(8)` produced a 16-char hex string; two `randomUUID()` calls
  differed and had the right shape (36 chars, hyphens at 8/13/18/23,
  version nibble `4` at position 14).
- [x] T6 Confirmed `--wasm` both compiles AND runs correctly (installed
  wasmtime to actually execute the compiled module, not just check it
  compiles) -- identical output to the native run, including the same
  sha256 digest. This is the payoff of picking `crypto` over
  `child_process`: zero wasm-specific work needed, unlike `os`/
  `process.pid()`.
- [x] T7 `zig build test` passes. `zig build conformance` run clean (no
  concurrent builds, same pre-existing failures, no new ones).
- [x] T8 Updated `website/stdlib.html`: new `crypto` quick-jump list + per
  function blocks; updated Planned table; added to the docs-nav sidebar.
- [x] T9 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `createHash`'s streaming API (needs a
stateful hash-builder object), `createHmac`/`sign`/`verify` (asymmetric/keyed
crypto, much larger surface), `pbkdf2`/`scrypt` (deliberately deferred, not
rushed), `md5`/`sha1` as named functions (available from the same source
later if needed).
