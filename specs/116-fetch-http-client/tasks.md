# Tasks — Spec 116 fetch + HTTP client

- [x] Agent A: `http.request`/`http.get` client in `host_http.zig` (net socket, response parse, framing)
- [x] Agent B: `Headers` global (`host_headers.zig`)
- [x] Agent C: `Response`/`Request` globals (`host_fetch_body.zig`)
- [x] Agent D: `AbortController`/`AbortSignal` globals (`host_abort.zig`)
- [x] Copy the 4 owned files from the worktrees; clean worktrees
- [x] Wire 3 new NativeIds (`headers_method`/`fetch_body_method`/`abort_method`) + dispatch + constructNT
- [x] Install globals from `host_setup.zig`
- [x] Implement `fetch()` glue (drive http client → Response promise)
- [x] Fix empty-body bug (accumulate into a `%body%` string, not a JS array)
- [x] Smoke: Headers / Response.json / Abort / http client round-trip — all green
- [x] End-to-end: `fetch(...).then(r=>r.json()/r.text())` GET + POST + headers — green
- [x] Gate: `zig build test` + `lint` + `bench` + Test262 language differential (0 regressions)
- [ ] (spec 117) Fix async/await in host run mode → unblocks `await fetch()`
- [ ] (later) TLS → `https` / `fetch('https://…')`
