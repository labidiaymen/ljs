# Spec 126 — HTTPS via std.http.Client: `fetch('https://…')` over real TLS

**Status:** Done (2026-06-22, v1). `fetch('https://…')` now performs a real TLS 1.3 request (handshake,
server-cert verification against the system trust store, HTTP, redirects) and returns a Response.

## Approach
Zig std ships `std.http.Client`, which bundles TLS + HTTP + cert verification + redirects, and uses the
same `std.Io` ljs already holds (`self.io`). New `host_https.zig` `fetchBlocking(method, url, headers,
body)`: a one-shot BLOCKING request — `client.ca_bundle.rescan(arena, io, Clock.now(.real, io))` to load
the system roots, `client.fetch(.{ .location=.{.url}, .method, .payload, .response_writer })` into an
allocating writer, returns `{status, body}`. The `fetch()` glue routes an `https://` URL here and builds
a Response directly (the async libxev http client is plaintext-only).

## Result
- `fetch('https://example.com/').then(r=>r.text())` → 200 + the real HTML body (TLS verified).
- Host-only — 0 Test262 impact; test/lint/bench green.

## Caveats / next
- BLOCKING: the round-trip stalls the event loop (fine for one-shot scripts; an async libxev-TLS path is
  a later refinement).
- v1 sends no custom request headers and exposes only status+body on the Response (no response headers
  yet — `std.http.Client.fetch` returns only the status; the lower-level `Request` API gives headers).
- The **`https` module** (`require('https')` → `https.get`/`https.request`) is the next cycle — that's what
  unblocks axios / ws / node-fetch (they require the module, not fetch). Same `fetchBlocking` engine,
  delivered via the http-client event shape.
