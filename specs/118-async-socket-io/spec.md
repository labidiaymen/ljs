# Spec 118 — async socket I/O: `await fetch()` / `net`/`http` from inside an async body

**Status:** Done (2026-06-22) — `await fetch()` and `net`/`http` client I/O initiated INSIDE an
async/generator body now work end-to-end. Conformance delta: **0 Test262 regressions** (host-only
routing; the interpreter change is a new helper not on the conformance path).

## Problem (the spec-117 follow-up)
Async/generator bodies run on their own OS thread with a fresh `Interpreter`. spec 117 routed the
timer/microtask/nextTick queues to the root via `hostLoop()`, but the **libxev I/O state was still
per-interpreter** and not inherited:
- `io_loop` — `host_io.ensureLoop(body)` saw `body.io_loop == null` and created a SECOND orphan loop
  that `runEventLoop` never drives → a body-thread connect was never serviced (hang).
- `io_handles` + `next_io_id` — a `ClientState`/`SocketState` registered in the body's map under id N
  collided with a *different* entry at id N in the root's map; the loop-thread connect/read callbacks
  (which run on the root) dereferenced the wrong-typed pointer → **segfault** in `clOnConnect`
  (`cl.method`/`cl.path` were garbage).
- `io_pending` + `st.interp` — accounting + event-target captured the transient body interpreter.

## Fix
Route ALL libxev state through `self.hostLoop()` (the root event-loop interpreter):
- `host_io.ensureLoop`/`maybeLoop` resolve + store the loop on the root.
- `host_http`/`host_net` `registerHandle`/`handlePtr` use the root's `io_handles` + `next_io_id`.
- `host_net` arm sites bump `self.hostLoop().io_pending`; sockets/servers set `st.interp = self.hostLoop()`.
- Removed the spec-117 fast-fail guard (the real fix supersedes it).

Safe without locks: the body and loop threads hand off cooperatively (only one runs at a time), and
all I/O submission/processing now happens against the single root loop.

## Acceptance (verified)
- `await fetch('http://…')` from an async listen callback: GET (status/ok/headers/`json()`/`text()`),
  POST with a body — all correct, byte-consistent with the sync `.then` path.
- `http.get(...)` and `srv.close()` from inside an async body: work (was hang→segfault).
- No regression: top-level async / async-from-timer / async sleep still work; sync `.then` fetch and
  the http SERVER hot path unchanged; `zig build bench` no regression.

## Out of scope
- TLS / `https` / `fetch('https://…')` — next slice.
