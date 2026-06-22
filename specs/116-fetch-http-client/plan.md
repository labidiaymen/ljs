# Plan — Spec 116 fetch + HTTP client

## Approach
4 parallel worktree agents on **disjoint files**, then a sequential main-thread integration:
- Agent A → `src/host_http.zig` (+577 lines): `http.request`/`http.get` client (reuses `.http_method`
  kind — no new NativeId; builds on `net`).
- Agent B → `src/host_headers.zig` (new): `Headers` global.
- Agent C → `src/host_fetch_body.zig` (new): `Response`/`Request` globals.
- Agent D → `src/host_abort.zig` (new): `AbortController`/`AbortSignal` globals.

## Integration (main thread)
- New NativeIds: `headers_method`, `fetch_body_method`, `abort_method` (`runtime_types.zig`).
- Dispatch + `unreachable` host-list (`interp_native.zig`); constructibility arms (`interp_expr.zig`,
  `constructNT`) — `Headers`/`Response`/`Request`/`AbortController` `new`-able; `AbortSignal` is NOT.
- Install all globals from `host_setup.zig` after the URL install.
- **`fetch()` glue** added to `host_fetch_body.zig`: a `fetch_fn` native creates a Promise, calls
  `http.request` with a `fetch_cb` response trampoline, accumulates `'data'` into a hidden `%body%`
  string (NOT a JS array — array `.length` isn't tracked through `get("length")`, the bug that first
  returned empty bodies), and on `'end'` builds a `Response` + `fulfillPromise`.

## Constitution Check
- **Correctness leads:** each module verified byte-identical to Node in isolation; the integrated
  fetch round-trips against ljs's own server.
- **No Test262 regression:** host-only surface; engine arms are additive and inert on the conformance
  path. Language differential run (engine files touched).
- **Perf gate:** `zig build bench` — no ljs-vs-self regression (host code is off the hot interpreter path).

## Risk
- `await fetch()` exposed a pre-existing async-on-OS-threads bug in host run mode → carved out as
  spec 117 (the real next unlock). Does not block `.then()`-style fetch.
