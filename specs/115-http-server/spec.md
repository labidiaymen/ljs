# Spec 115 — http server (with keep-alive)

**Status:** In progress (gates).
**Axis:** Node host runtime. The gateway to running real server frameworks (Express). Built by a
background agent, integrated on the main thread; keep-alive added by the integrator after the perf test.

## Why
`http` is the highest-leverage Node module for real apps — and the prerequisite for Express. Built ABOVE
`net` (libxev TCP): an `http.Server` owns an internal `net.Server` and is driven through net's JS surface
(`'connection'`/`'data'`/`'end'` + `socket.write`/`end`). The module is a pure HTTP/1.1 protocol layer.

## What landed (`host_http.zig`, new)
- `http.createServer([cb])` → `http.Server` (EventEmitter); `server.listen(port[,host][,cb])` +
  `'listening'`, `server.close()`, `server.address()`.
- `req` (IncomingMessage, readable): `method`/`url`/`httpVersion`/`headers` (lowercased)/`socket`;
  emits `'data'` (Buffer) + `'end'`.
- `res` (ServerResponse, writable): `statusCode`/`setHeader`/`getHeader`/`hasHeader`/`removeHeader`/
  `writeHead`/`write`/`end`/`headersSent`; auto `Date` + `Content-Length`; emits `'finish'`.
- **Keep-alive (integrator add):** HTTP/1.1 persistent connections — the connection parser resets and
  re-drives after each response (drains the consumed request bytes, supports pipelined/sequential
  requests on one socket) instead of closing. `Connection: keep-alive` sent when the client wants it AND
  the body is self-framing (Content-Length/chunked); `Connection: close` otherwise. Verified: distinct
  POST bodies on one socket frame correctly (`AAA`/3, `BBBBB`/5).

## The perf result (the point of this cycle)
Raw `http` `/json`, 20k req / 50 concurrent, same load client for both:

| | req/s |
|---|---:|
| ljs (JIT, keep-alive) | **10,905** |
| Node 22 (keep-alive) | 11,435 |

**ljs ≈ 95% of Node — basically par.** Before keep-alive ljs was 885 rps (~12× slower); the entire gap
was keep-alive, NOT engine speed (a new-connection-per-request control showed 972 vs Node 942 — ljs
already matched). The integer JIT is irrelevant here (string/socket work, not numeric loops): 927 vs 885.

## Out of scope (later)
Chunked transfer-encoding, `http.request`/`http.get` CLIENT (needed for outbound — and, with TLS, for an
npm client), Expect/100-continue, trailers, HTTPS. Express itself still needs gap-fixes to run (a
`TypeError` in its dep graph — separate task).

## Success criteria
- Correct GET/POST incl. keep-alive framing (done); `zig build test`/`lint`/`bench` green; Test262
  language differential 0 regressions (http native kind never appears on the engine path).
