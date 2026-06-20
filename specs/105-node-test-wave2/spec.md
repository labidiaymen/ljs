# Spec 105 — node-test wave 2: knock out the top harness blockers (path/buffer/process/querystring)

Status: In progress · Owner: Aymen

## Goal
Raise the measured node-test number (baseline 34/290 = 11.7%, spec 104) by clearing the highest-count,
lowest-cost failure buckets the harness surfaced. 4 independent units (parallel agents). Host-only →
0 Test262 regressions. Each agent VALIDATES against the REAL Node tests it targets
(`vendor/node-test/parallel/test-<mod>-*.js`, runnable directly: `ljs run <file>; echo $?`).

## Unit A — `path.posix` / `path.win32`
The 15 `path` tests almost all fail with "Cannot read properties of null/undefined" because they call
`path.win32.dirname(...)` / `path.posix.basename(...)` and those namespaces don't exist. Add
`path.posix` and `path.win32` — each a FULL path namespace (join/resolve/dirname/basename/extname/
normalize/isAbsolute/relative/parse/format/sep/delimiter) with the correct platform rules (win32:
`\`+`/` separators, drive letters, UNC; posix: `/`), and `path` itself = the platform default
(win32 on Windows). Also `require('path/posix')` / `require('path/win32')`. Target: ~12 path tests.

## Unit B — `buffer` module + the indexOf/includes panic + validation
- 12 buffer tests fail on `require('buffer')` — add the **`buffer` core module** (exports `{ Buffer,
  kMaxLength (≈ 2^32-1 or a sane cap), constants: { MAX_LENGTH, MAX_STRING_LENGTH }, SlowBuffer
  (=alloc), isAscii?/isUtf8? optional, Blob optional }`).
- **2 ENGINE PANICS** in `Buffer.indexOf`/`includes`: `@intFromFloat out of bounds` on a huge/NaN/
  -Infinity byteOffset — CLAMP before the cast (this is a crash, fix first).
- 11 "Missing expected exception": Buffer methods must THROW on bad input (RangeError on OOB
  read/write offsets, TypeError on wrong arg types, `Buffer.alloc(-1)` / huge size → RangeError, etc.)
  — add the validation the tests assert.throws on.
Target: buffer 5/63 → 25+.

## Unit C — `process` surface
29 process tests fail "value is not a function" (missing methods; the rest need worker_threads/
child_process/net — out of scope). Read the failing `test-process-*.js` to see which; add the cheap
ones: `process.hrtime()` + `process.hrtime.bigint()`, `process.memoryUsage()` (+`.rss()`),
`process.cpuUsage()`, `process.emitWarning()`, `process.exitCode` (get/set), `process.on`/`once`/
`emit`/`removeListener` (make `process` an EventEmitter — reuse host_events; drives `'exit'`/`'warning'`),
`process.uptime()`, `process.kill` (stub/no-op or ESRCH), `process.umask()`, `process.nextTick`
(exists), `process.allowedNodeEnvironmentFlags` (a Set), `process.features` (object), `process.release`
(object), `process.config` (object). Target: process 8/91 → 25+.

## Unit D — `querystring` module + util/events small wins
- New **`querystring` core module** (`host_querystring.zig`): `parse`/`decode`, `stringify`/`encode`,
  `escape`, `unescape` (+ `parse` options sep/eq minimal). Target: querystring 3/3.
- `util`/`events` "value is not a function" gaps that don't need vm/internal bindings: add the missing
  methods the failing `test-util-*`/`test-events-*` call (read them; e.g. `util.inspect` options,
  `util.isDeepStrictEqual`, `EventEmitter.once`/`EventEmitter.on` static, `getMaxListeners`, etc.).

## Gate
build/test/lint/bench green; `language/` 0 regressions (host-only). Success = the harness total rises
materially (re-run `scripts/run-node-tests.sh --shim` after integration). Out of scope this wave:
`net`/`stream`/`http`/`vm`/`worker_threads`/`child_process`, WPT-grade `url`, `internal/*` bindings.
