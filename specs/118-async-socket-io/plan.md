# Plan — Spec 118 async socket I/O

## Files touched
- `src/host_io.zig`: `ensureLoop`/`maybeLoop` resolve the loop on `self.hostLoop()` (root).
- `src/host_http.zig`: `registerHandle`/`handlePtr` use the root's `io_handles` + `next_io_id`.
- `src/host_net.zig`: `registerHandle`/`handlePtr` → root; `st.interp = self.hostLoop()` (socket +
  server creation); `io_pending` arm sites → `self.hostLoop().io_pending`; removed the spec-117 guard.

## Diagnosis path (recorded so the next I/O-from-body bug is fast)
1. Body-thread connect HUNG → `ensureLoop(body)` made an orphan loop (`io_loop` per-interp).
2. After routing the loop → SEGFAULT in `clOnConnect` formatting `cl.method` → `io_handles` per-interp
   id collision returned a wrong-typed pointer. Debug build + filtering compiler_rt `memcpy` frames
   surfaced the exact call site.
3. Routing `io_handles`/`next_io_id`/`io_pending`/`st.interp` to the root fixed it.

## Constitution Check
- **Correctness leads:** verified `await fetch()` GET/POST/json/text end-to-end + no async/server
  regressions; Test262 language differential 0 regressions.
- **Perf gate:** `hostLoop()` is `host_timer_parent orelse self` (one inlined branch); on the root
  (server hot path) it is `self`. `zig build bench` shows no regression.
- **No race:** cooperative thread handoff (one active at a time); single root loop owns all I/O.
