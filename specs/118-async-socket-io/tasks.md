# Tasks — Spec 118 async socket I/O

- [x] Diagnose hang: `ensureLoop(body)` creates an orphan loop (`io_loop` per-interp)
- [x] Route `host_io.ensureLoop`/`maybeLoop` through `hostLoop()`
- [x] Diagnose segfault: `io_handles`/`next_io_id` per-interp id collision (debug build + trace)
- [x] Route `host_http`/`host_net` `registerHandle`/`handlePtr` to the root
- [x] Route `io_pending` arm sites + `st.interp` to the root
- [x] Remove the spec-117 fast-fail guard
- [x] Verify `await fetch()` GET/POST/json/text + `srv.close()` from async body
- [x] Regression: top-level/timer/sleep async, sync `.then` fetch, http server hot path, bench
- [x] Gate: test + lint + bench + Test262 language differential (0 regressions)
- [ ] (next) TLS → `https` / `fetch('https://…')`
