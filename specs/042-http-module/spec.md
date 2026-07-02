# Spec 042: http module

## Goal

Replace the two existing bare-bones global functions (`httpGet(url) -> i64`,
status-only; `serve(port, body)`, one canned response to every request)
with a real `http` namespace covering the practical core of
[Node's `http` module](https://nodejs.org/api/http.html): making requests
with a method/body and reading the real response, and running a server that
actually inspects the request and returns a real per-request response.

**This is explicitly not a 1:1 port of Node's `http` API**, and that's a
deliberate scoping decision, not an oversight -- see "Why not the real
Node shape" below. What ships is the practical intent of the module
(client requests, server request/response), in a shape that fits Lumen's
existing static-function-and-record stdlib pattern, the same pattern
every other module (`fs`, `path`, `url`, `child_process`) already uses.

## Node's real API surface (for reference, from nodejs.org/api/http.html)

- **Top-level**: `http.request(options, callback)`, `http.get(options,
  callback)`, `http.createServer([options], requestListener)`.
- **Classes**: `http.Server` (emits `'request'`/`'connection'`/etc.),
  `http.IncomingMessage` (headers/method/url/statusCode, a readable
  stream), `http.ServerResponse`/`http.ClientRequest` (both extend
  `OutgoingMessage`: `write()`/`end()`/`setHeader()`, a writable stream),
  `http.Agent` (connection pooling).
- **Constants**: `http.METHODS`, `http.STATUS_CODES`.
- **Utilities**: header validation, `http.globalAgent`, proxy config.

## Why not the real Node shape

Every one of Node's classes above is built on two things Lumen doesn't
have: **`EventEmitter`** (`'request'`, `'data'`, `'end'`, `'error'`, ...)
and **streams** (chunked, backpressure-aware reading/writing). Both are
real, separate, much larger features (an `EventEmitter` needs a listener-
registration and dispatch mechanism; a `Stream` needs an abstraction over
chunked async I/O) that nothing in the stdlib has built yet -- `fs`, `os`,
and `process` all hit and documented the same wall for their own
async/streaming gaps. Porting the literal class hierarchy without those
foundations would mean fake classes that don't behave like Node's at all,
which is worse than not having them.

Two more Node idioms don't fit today for reasons already established
elsewhere in the stdlib:

- **Header collections**: Node passes headers as a plain object (or a
  `Headers`-like map). Lumen has no growable-array or `Map`-construction
  path from inside a stdlib builtin (the same gap that deferred
  `querystring`/`URLSearchParams` off of `url`). Custom headers are
  deferred for the same reason.
- **`(req, res) => { ... }` as the server callback**: block-bodied arrow
  functions only parse in specific contexts today (confirmed while
  testing spec 038's timers), and Node's mutate-`res`-in-place style
  doesn't fit the functional, record-returning shape the rest of the
  stdlib uses. The handler is a **named top-level function that takes a
  request record and returns a response record** instead -- the same
  working pattern already used for `setInterval`'s callback.

## API (the practical subset that ships)

### Client (Phase 1)

| Function | Type | Notes |
| --- | --- | --- |
| `http.request(url, method, body)` | `(string, string, string) -> HttpResponse` | one-shot request; `body` is ignored (pass `""`) for methods that don't take one |
| `http.get(url)` | `string -> HttpResponse` | convenience wrapper, `http.request(url, "GET", "")` |

`HttpResponse` record: `{ status: int, body: string, ok: bool }`. `ok` is
`status >= 200 and status < 300`, sparing every caller from writing that
range check themselves (a small, deliberate addition beyond Node's own
shape, which leans on this being cheap to compute once here). Built on
`std.http.Client.fetch`'s existing `method`/`payload`/`response_writer`
options -- confirmed capable of exactly this (checked the real struct
definition directly, not assumed), a genuine capability upgrade over the
current status-only `httpGet`.

### Server (Phase 2)

| Function | Type | Notes |
| --- | --- | --- |
| `http.createServer(port, handler)` | `(int, (HttpRequest) -> HttpResponse) -> void` | blocking accept loop, calls `handler` per request, never returns |

`HttpRequest` record: `{ method: string, path: string, body: string }`.
`HttpResponse` (server-returned) record: `{ status: int, body: string }`.
Real per-request parsing (method, path, `Content-Length`-based body),
reusing the exact manual HTTP/1.1 parsing approach the playground's own
compile service (`playground/server.zig`) already proves works -- not a
new, unverified technique.

## Migration note

Checked for existing call sites of the two functions this replaces:
`httpGet`/`serve` appear nowhere except their own `website/stdlib.html`
Planned-table mention -- no example, test, or playground code depends on
either. Free to alias, supersede, or remove them during implementation
without a compatibility concern.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Custom request/response headers (set or read) | a header-collection type; the same growable-array/`Map`-construction gap that deferred `url`'s querystring |
| Response headers on the client side | `std.http.Client.fetch`'s convenience wrapper only surfaces `status`; reading response headers needs the lower-level request/response object flow underneath it, not investigated this pass |
| `http.Server`/`IncomingMessage`/`ServerResponse`/`ClientRequest`/`Agent` as real classes, or any `'event'` name | needs `EventEmitter`, not built yet |
| Streaming request/response bodies (chunked reads, backpressure) | needs a `Stream` abstraction, not built yet -- everything here is one-shot, whole-body |
| Concurrent/multi-connection serving | the accept loop is single-threaded and blocking, matching the existing `serve()`'s simplicity; a real concurrent server is a separate, later feature |
| `http.METHODS`/`STATUS_CODES` constants | low value without more consumers of them yet; easy to add later as plain string-array/record constants |
| HTTPS/TLS-specific configuration, WebSocket upgrade, `Agent`/connection pooling exposure | each a real, separate feature; `std.http.Client` handles basic TLS internally already for `https://` URLs on the client side, just not exposed as configuration |
