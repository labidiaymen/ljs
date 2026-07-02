# Tasks: http module

## Phase 1 -- client

- [ ] T1 Add `"http"` to the parser's `isStdNamespace` list. New
  `httpCallType` in `lumen_check_stdlib.zig`, wired into `staticCallType`.
- [ ] T2 `registerLumenHttpResponse` -- synthetic `{ status: int, body:
  string, ok: bool }` record, following `registerLumenUrlParts`'s exact
  pattern.
- [ ] T3 `http.request(url, method, body)` -- confirm `std.http.Client
  .fetch`'s `method`/`payload`/`response_writer` options actually behave
  as expected together (method override, payload sent, response body
  captured) with a real request against a real endpoint, not just that it
  compiles.
- [ ] T4 `http.get(url)` -- thin wrapper over `request(url, "GET", "")`.
- [ ] T5 Verify: a GET against a known-stable endpoint returns a plausible
  status/body/`ok`; a POST with a body actually sends it (verify against
  an echo-style endpoint or by reading back what was received); a request
  to an unreachable host degrades to a sane fallback rather than crashing.
- [ ] T6 Decide whether the old bare `httpGet(url)` global function
  becomes an alias for `http.get(url)` or is removed outright -- check
  for existing call sites/examples referencing it first.
- [ ] T7 `zig build test` passes. `zig build conformance` run clean.
- [ ] T8 Update `website/stdlib.html`: new `http` quick-jump list + client
  function blocks; update the Planned table.
- [ ] T9 Commit, push, redeploy `lumen-playground`.

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
