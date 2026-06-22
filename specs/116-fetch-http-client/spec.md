# Spec 116 — `fetch` + HTTP client (WHATWG fetch stack on the Node host axis)

**Status:** Done (2026-06-22) — fetch stack lands; `.then()`-style usage works end-to-end.
Conformance delta: **0 Test262 regressions** (language 42315 / 95.1% held); this is host-axis
surface, inert on the Test262 path by construction.

## Summary
Add the outbound HTTP capability + the WHATWG `fetch` API above the existing `net`/`http` host
layer (plaintext `http://`; TLS/`https` is a later slice). Built by **4 parallel worktree agents**
(disjoint files) + a main-thread integration pass that wired the engine kinds and the `fetch()` glue.

## In scope
- **`http.request` / `http.get`** (client) on `host_http.zig`, reusing the server's parser style and
  `net` for the socket. ClientRequest (writable EventEmitter) + response IncomingMessage
  (statusCode/statusMessage/headers, `'data'`/`'end'`). Body framing: Content-Length, **chunked
  transfer-decoding**, and read-until-close.
- **`Headers`** (`host_headers.zig`) — WHATWG case-insensitive multi-map.
- **`Response` / `Request`** (`host_fetch_body.zig`) — the Body mixin (`text`/`json`/`arrayBuffer`/
  `clone`), real Promises, statics (`Response.json`/`error`/`redirect`).
- **`AbortController` / `AbortSignal`** (`host_abort.zig`) — EventTarget-shaped, `timeout`/`any`.
- **`fetch(input[, init]) -> Promise<Response>`** (glue in `host_fetch_body.zig`) — drives
  `http.request`, accumulates the body, fulfills with a `Response`.

## Out of scope (follow-ups)
- **TLS / `https` / `fetch('https://…')`** — next slice (Zig std `crypto.tls` over the libxev socket).
- Redirect following, connection pooling/agents, cookies, `FormData`/streaming bodies.
- **`await fetch()` in host `run` mode** — blocked by a SEPARATE pre-existing bug (async function
  bodies run on `std.Thread.spawn` OS threads whose execution/stdout is lost in host run mode; see
  spec 117). `fetch().then(…)` works today; `await` does not, but that affects ALL async/await in
  host scripts, not fetch specifically.

## Acceptance (verified)
- `new Headers({'Content-Type':'text/plain'})` + append/get case-insensitive + combine → byte-identical to Node.
- `new Response('{"a":1}',{status:201}).json()` resolves `{a:1}`, `.ok===true`.
- `new AbortController()` → `.signal.aborted` flips on `.abort()`, fires `'abort'` once.
- In-process `http.createServer` + `fetch('http://127…/x').then(r=>r.text())` → status 200, correct body.
- POST with a body + custom response headers round-trips; `r.headers.get('x-custom')` works.
