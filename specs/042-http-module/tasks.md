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

- [ ] T10 `registerLumenHttpRequest` -- synthetic `{ method: string,
  path: string, body: string }` record (the handler's parameter type).
- [ ] T11 `http.createServer(port, handler)` -- `handler` is a named
  top-level function reference (`(HttpRequest) -> HttpResponse`), not an
  inline callback (block-bodied arrows don't parse as inline arguments
  today, per spec 038's finding). Real HTTP/1.1 request-line + header
  parsing (method, path, `Content-Length`-based body), reusing
  `playground/server.zig`'s proven manual-parsing approach rather than
  inventing a new one.
- [ ] T12 Verify: a real client (`curl`, or `http.get` against the
  server) receives the exact status/body the handler returned; the
  handler correctly sees the real method/path/body of an incoming
  request (not placeholder/canned values, unlike the old `serve()`); an
  unhandled/malformed request doesn't crash the accept loop.
- [ ] T13 Decide whether the old `serve(port, body)` global function
  stays (simplest possible canned-response case) or is superseded/removed
  in favor of `http.createServer` -- check the playground/examples for
  existing usage first.
- [ ] T14 `zig build test` passes. `zig build conformance` run clean.
- [ ] T15 Update `website/stdlib.html`: server function block(s), examples
  showing a real request-inspecting handler.
- [ ] T16 Commit, push, redeploy `lumen-playground`.

## Phase 3 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: custom headers (needs a header-
collection type), client-side response headers (needs the lower-level
request/response flow, not investigated), real
`Server`/`IncomingMessage`/`ServerResponse`/`ClientRequest`/`Agent` classes
and any `EventEmitter`-based event (needs `EventEmitter`, not built),
streaming bodies (needs a `Stream` abstraction, not built), concurrent
serving, `METHODS`/`STATUS_CODES` constants, HTTPS/TLS configuration,
WebSocket upgrade.
