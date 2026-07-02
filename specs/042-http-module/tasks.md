# Tasks: http module

## Phase 1 -- client

- [x] T1 Added `"http"` to the parser's `isStdNamespace` list. New
  `httpCallType` in `lumen_check_stdlib.zig`, wired into `staticCallType`.
- [x] T2 `registerLumenHttpResponse` -- synthetic `{ status: int, body:
  string, ok: bool }` record, following `registerLumenSpawnResult`'s
  exact pattern.
- [x] T3 `http.request(url, method, body)` -- confirmed `std.http.Client
  .fetch`'s `method`/`payload`/`response_writer` options work together
  exactly as expected, against real endpoints (not just that it
  compiles): `response_writer` needed `std.Io.Writer.Allocating` (a
  growable-buffer writer) to actually capture the body, and
  `std.meta.stringToEnum(std.http.Method, method)` converts the method
  string cleanly.
- [x] T4 `http.get(url)` -- reuses `__httpRequest` directly with
  hardcoded `"GET", ""` args in codegen, no separate wrapper function
  needed.
- [x] T5 Verified: `http.get("https://example.com")` returned `status:
  200, ok: true`, with the body containing "Example Domain";
  `http.request("https://postman-echo.com/post", "POST", "hello=world")`
  returned `status: 200` with the body echoing back `"hello=world"`
  (confirms the payload was genuinely sent, not just accepted silently);
  a request to a nonexistent domain returned the `status: -1, ok: false`
  fallback rather than crashing. (First test run hit `httpbin.org`
  returning 503 for everyone, confirmed via plain `curl` -- a real
  third-party outage, not a bug here; switched to `example.com`/
  `postman-echo.com`.)
- [x] T6 Decided: left the old bare `httpGet(url)`/`serve(port, body)`
  global functions as-is (no real call sites existed per the spec's
  migration note, so no compatibility break either way) rather than
  aliasing or removing them -- lowest-risk choice; `http.get`/`request`
  are the primary, documented path going forward.
- [x] T7 `zig build test` passes. `zig build conformance` run clean.
- [x] T8 Updated `website/stdlib.html`: new `http` quick-jump list +
  client function blocks, tagged `target-wasm-limited` (confirmed by
  actually running the compiled wasm via wasmtime: it compiles cleanly
  but every request returns the connection-failure fallback under WASI,
  which has no network access -- the same "compiles, non-functional"
  shape as `child_process.spawnSync`, not a crash); updated the Planned
  table.
- [x] T9 Commit, push, redeploy `lumen-playground`.

## Phase 2 -- server

- [x] T10 `registerLumenHttpRequest` -- synthetic `{ method: string,
  path: string, body: string }` record (the handler's parameter type).
  The handler's *return* type reuses `__LumenHttpResponse` (the client's
  own response record), not a second, similar-but-different type -- `ok`
  goes unused server-side, the same "fill every field by hand"
  simplification `path.format`'s record parameter already established.
- [x] T11 `http.createServer(port, handler)` -- `handler` is a named
  top-level function reference (`(HttpRequest) -> HttpResponse`), not an
  inline callback (block-bodied arrows don't parse as inline arguments
  today, per spec 038's finding). Real HTTP/1.1 request-line + header
  parsing (method, path, `Content-Length`-based body), reusing
  `playground/server.zig`'s proven manual-parsing approach rather than
  inventing a new one. Hit and fixed a real ordering bug: the handler's
  parameter type annotation names `__LumenHttpRequest` directly, and that
  annotation is checked wherever the handler is *declared* -- which is
  textually before the `http.createServer` call that would otherwise lazily
  register the type (the pattern every other record-returning builtin
  uses). No prior builtin hit this, since their record types are only ever
  used as an inferred return value, never as a named parameter type that
  has to resolve before its registering call site is reached. Fixed by
  registering `__LumenHttpRequest`/`__LumenHttpResponse` eagerly,
  unconditionally, at the very start of type-checking, rather than lazily
  at first use. Also added clean, writable aliases (`HttpRequest`/
  `HttpResponse`) for the two internal double-underscore names -- a
  handler has to name its parameter/return types explicitly (unlike
  every other record-returning builtin, whose type only ever shows up as
  an inferred return value), so asking users to write the internal name
  directly would have been a real rough edge.
- [x] T12 Verified with a real server and real `curl` requests (not a
  simulated/in-process test): a GET received the exact status/body the
  handler returned; a POST correctly delivered its body to the handler
  (`req.body` matched exactly); the handler's real method/path/body were
  visible on every request (not placeholder/canned values, unlike the old
  `serve()`); returning a custom status code (404) from the handler for a
  specific path worked correctly, proving the handler's return value
  genuinely drives the response, not a hardcoded 200.
- [x] T13 Decided: left the old `serve(port, body)` global function as-is
  (same reasoning as `httpGet` in Phase 1 -- no real call sites, no
  compatibility break either way); `http.createServer` is the primary,
  documented path going forward.
- [x] T14 `zig build test` passes. `zig build conformance` run clean.
- [x] T15 Updated `website/stdlib.html`: server function block, an example
  showing a real request-inspecting handler with a custom status code.
- [x] T16 Commit, push, redeploy `lumen-playground`.

## Server performance vs Node (requested, not in the original plan)

Benchmarked with the *same* Node.js client hitting both servers (isolates
the server implementation as the only variable): 300 sequential GETs to a
Lumen server vs the same loop against a plain Node `http.createServer`.
Node initially won (~165ms vs Lumen's ~235ms, Lumen roughly 1.3-1.5x
slower). Root-caused, not just measured: Lumen's server was sending
`Connection: close` and tearing the socket down after every single
response (matching the old `serve()`'s exact behavior), forcing a fresh
TCP handshake per request, while Node's server keeps the connection alive
by default.

**Implemented HTTP keep-alive** in response, since this was a real,
identifiable root cause (unlike a design tradeoff to just document and
move past): the reader/writer are now set up once per accepted connection,
with an inner loop reading and answering requests off that same connection
until the client sends `Connection: close` or the connection drops.
Verified with `curl -v` against two requests on one connection: confirmed
"Re-using existing connection" for the second request rather than a new
TCP handshake. Re-verified correctness after the change: a custom status
code (404) for a specific path, a POST body correctly delivered, and an
explicit `Connection: close` request all still worked correctly. Re-ran
the benchmark: Lumen now measures ~139ms vs Node's ~157ms on the same
300-request loop -- modestly faster (~1.1-1.2x), not just closing the gap.

Still not attempted: idle-connection timeouts (a connection stays open
indefinitely as long as the client keeps sending requests) and
multi-connection concurrency (still one connection served at a time,
though its requests are now handled with keep-alive).

## Phase 3 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: custom headers (needs a header-
collection type), client-side response headers (needs the lower-level
request/response flow, not investigated), real
`Server`/`IncomingMessage`/`ServerResponse`/`ClientRequest`/`Agent` classes,
server lifecycle events via `EventEmitter<T>` (genuinely reachable now,
real follow-up), streaming bodies (needs a `Stream` abstraction, not
built), idle-connection timeouts and multi-connection concurrency (see
above -- keep-alive itself shipped), `METHODS`/`STATUS_CODES` constants,
HTTPS/TLS configuration, WebSocket upgrade.
