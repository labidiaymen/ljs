# Tasks: header/querystring support via Map

## Phase 1

- [x] T1 `url.parse`'s `__LumenUrlParts` record gains a `query: Map<string,
  string>` field. `__urlParse` constructs a `LumenMap([]const u8, []const
  u8)` internally (confirmed feasible with a standalone test before
  writing this task list), populated by splitting `search` on `&` and
  `=`. Verified: `?a=1&b=hello&c=3` parsed into a `Map` where `.get("a")`,
  `.get("b")`, `.get("c")` all returned the right values, `.get("z")`
  (missing key) returned `null`, `.size` (a property, not a method --
  confirmed by trying `.size()` first and getting a real type error)
  matched the entry count, and a URL with no query string produced an
  empty `Map` (`.size == 0`), not a crash.
- [x] T2 `http.request`/`http.get` gain a 4th positional arg,
  `headers: Map<string, string>` (`http.get`'s convenience wrapper
  constructs an empty `Map` internally in codegen, not exposed as a
  5th... 1st... user-facing arg). Passed through as
  `FetchOptions.extra_headers`, converted from the `Map`'s
  `keys_`/`values_` into a `[]std.http.Header` slice. Hit and fixed a
  real mutability bug: `alloc.alloc(...) catch &.{}` inferred the whole
  expression as the more restrictive `[]const T` (peer type resolution
  with the empty-array-literal fallback), even though `alloc.alloc`
  itself returns a mutable `[]T` -- fixed by using `catch unreachable`
  instead of a const-inducing fallback.
- [x] T3 `HttpResponse` gains a `headers: Map<string, string>` field.
  Hit and fixed a real bug: updated the checker's type registration but
  initially forgot the *separate* literal Zig struct-definition string
  emitted alongside `__httpRequest` (`pub const __LumenHttpResponse =
  struct { ... }`) -- two independent sources of truth for the same
  record shape that both need updating, not just one. Server side:
  `http.createServer`'s handler can now set custom response headers; the
  manual response-writing code in `__httpCreateServer` walks the
  record's `headers` map and writes each as its own header line.
- [x] T4 Client-side response headers: **investigated, not shipped this
  pass, a deliberate scope call, not an oversight**. Confirmed via
  reading the source that `std.http.Client`'s lower-level `Head`/
  `Response` type has `iterateHeaders()`, so this is genuinely reachable
  -- but getting there means restructuring `__httpRequest` off
  `client.fetch()`'s one-shot convenience wrapper onto
  `client.request()`/`sendBodiless`/`sendBodyComplete`/`receiveHead()`,
  several method signatures inferred from naming but never verified
  against real behavior. Given the existing `fetch()`-based flow is
  already working *and* already benchmarked (spec 042's ~1.5x-faster-
  than-Node result), rewriting it under time pressure risked regressing
  a real, hard-won result for an unverified API surface. `headers` on
  the client's returned response is present but currently always empty
  -- documented in code and in the website docs, not silently wrong.
- [x] T5 Verified end to end against real endpoints/servers, not
  simulated: a custom request header (`X-Test-Header`) sent via
  `http.request` was confirmed present in postman-echo.com's
  headers-echo response body; a custom response header
  (`X-Custom-Header`) set by a `http.createServer` handler was confirmed
  present in a real `curl -D -` response. Re-verified no regressions:
  `http.get`'s existing behavior, a POST with a body, the nonexistent-
  domain fallback, and the server's keep-alive connection reuse (`curl
  -v` showing "Re-using existing connection") all still work correctly
  after the signature/struct changes.
- [x] T6 `zig build test` passes. `zig build conformance` run clean.
- [x] T7 Updated `website/stdlib.html`.
- [x] T8 Commit, push, redeploy `lumen-playground`.
