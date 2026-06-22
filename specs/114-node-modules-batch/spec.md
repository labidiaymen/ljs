# Spec 114 — Node modules batch: stream + string_decoder + crypto/util expansion

**Status:** In progress (integration + gates).
**Axis:** Node host runtime. Built via **four parallel worktree agents** (one per module), integrated
sequentially on the main thread with a single build/test/lint/bench + Test262 gate.

## Why
After `fs` (spec 113), the next high-leverage Node surface is the **stream** stack (so many packages
and core modules build on it) plus the decoder/crypto/util gaps real packages hit. Parallelizing across
disjoint subsystems is the fast way to land several at once.

## What landed
- **`stream`** (`host_stream.zig`, new) — `Readable` (push/read/pipe/pause/resume, `'data'`/`'end'`,
  flowing on a `'data'` listener), `Writable` (`new Writable({write})`, `_write`, `'finish'`, optional
  `final`), `Transform`/`PassThrough`, `Duplex`. Instances are EventEmitters and subclassable;
  emissions deferred via the interpreter's next-tick queue (Node-like async timing). *Subset:* object
  mode / backpressure (highWaterMark) / `setEncoding` decode / `cork`/`destroy`/`pipeline` are no-ops
  or omitted (noted in the file) — a later cycle.
- **`string_decoder`** (`host_string_decoder.zig`, new) — `StringDecoder` with chunk-boundary-safe
  `write`/`end`. utf8 + utf16le/ucs2 handle multibyte/surrogate splits across writes; ascii/latin1/
  hex/base64 whole. Byte-identical to Node on every split case.
- **`crypto`** (`host_crypto.zig`) — `createHmac` (md5/sha1/sha224/sha256/sha384/sha512), `pbkdf2Sync`
  (sha1/224/256/384/512), `createHash` += sha224/sha384, `timingSafeEqual`. Digests byte-identical to Node.
- **`util`** (`host_util.zig`) — `callbackify` (real, via the native Promise helpers), `util.types.*`
  predicates filled out. `promisify`/`inherits`/`format`/`inspect` were already complete.

## Engine wiring (shared files — done by the integrator, not the agents)
Two new native kinds (`stream_method`, `string_decoder_method`) added to `runtime_types.NativeId`,
dispatched in `interp_native.callNative`, made constructible in `interp_expr.constructNT`, and
registered in `host_require.zig` (core_modules + buildCoreModule). Host-only — inert on the Test262 path.

## Success criteria
- Each module byte-identical to Node 22 on its smoke test (verified). `zig build test`/`lint`/`bench`
  green; Test262 language differential = 0 regressions (host kinds never appear on the engine path).
