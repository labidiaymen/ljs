# Tasks: header/querystring support via Map

## Phase 1

- [ ] T1 `url.parse`'s `__LumenUrlParts` record gains a `query: Map<string,
  string>` field. `__urlParse` constructs a `LumenMap([]const u8, []const
  u8)` internally (confirmed feasible with a standalone test before
  writing this task list), populated by splitting `search` on `&` and
  `=`.
- [ ] T2 `http.request`/`http.get` gain a 4th positional arg,
  `headers: Map<string, string>` (empty `Map` for `get`'s convenience
  wrapper). Passed through as `FetchOptions.extra_headers` -- needs
  converting the `Map`'s key/value pairs into a `[]const http.Header`
  slice built from the map's `.keys()`/`.values()`.
- [ ] T3 `HttpResponse` gains a `headers: Map<string, string>` field.
  Server side: `http.createServer`'s handler can now set custom response
  headers; the manual response-writing code in `__httpCreateServer` walks
  the record's `headers` map and writes each as its own header line.
- [ ] T4 Client-side response headers: restructure `__httpRequest` off
  `client.fetch()`'s convenience wrapper onto the lower-level
  `client.request(...)`/wait/`iterateHeaders()` flow so the real response
  headers can be read into the returned `Map`. Verify this doesn't
  regress anything `fetch()` was doing for free (redirect handling, TLS
  via the CA bundle path, response body capture via `response_writer`)
  -- check each explicitly, don't assume the lower-level flow behaves
  identically.
- [ ] T5 Verify end to end against real endpoints/servers: a URL with a
  multi-key query string parses into the right `Map` entries; a request
  sent with custom headers is actually received with those headers by a
  real server (verify via an echo-style endpoint, the same technique
  spec 042 used for confirming POST bodies); a server that sets a custom
  response header is confirmed present in a real client's response.
- [ ] T6 `zig build test` passes. `zig build conformance` run clean.
- [ ] T7 Update `website/stdlib.html`: `url.parse`'s new `query` field,
  `http.request`'s new `headers` arg, `HttpResponse`'s new `headers`
  field, examples for each.
- [ ] T8 Commit, push, redeploy `lumen-playground`.
