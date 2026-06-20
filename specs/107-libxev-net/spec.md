# Spec 107 — libxev integration + `net` (TCP) — the I/O foundation

Status: **Done** (commit pending) · Owner: Aymen

## Outcome (measured)
- **libxev** adopted as the first external dependency (commit `9ce8e8e`, pinned by hash; verified to
  compile/link/run against Zig 0.16.0 on Windows/IOCP). Integrated into the event loop; the pure-timer
  / Test262 / bench path is unchanged by construction (`io_pending` stays 0).
- **`net` works end-to-end**: a TCP echo server (incl. 3 concurrent connections) round-trips with a
  graceful `'end'`/`'close'` teardown; `isIP/isIPv4/isIPv6` correct. Client + server are EventEmitters
  over libxev TCP.
- **Gate**: `build`/`test`/`lint` green; **`language/` 0 regressions** (95.1% held — host-only);
  **`bench` ok** (the stale baseline — HEAD itself was +14.5% from machine drift, + ~3% inherent
  libxev-linking cost — was re-recorded on this machine per user direction; ljs-vs-self now ±2%).
- **Deferred to follow-on cycles**: `stream` (proper Duplex; make `Socket` a true Duplex) → 108;
  `http`/`https` → 109. The node-test vendor script now also fetches `net`/`stream`/`http` families
  (re-run `scripts/vendor-node-test.sh` to measure the harness delta when those cycles land).
- **IOCP lessons captured in `host_net.zig`**: `.rearm` is unsafe for accept (WSAEINVAL) and read
  (silent no-rearm) — re-issue + `.disarm` instead; create sockets only AFTER the loop exists;
  accepted sockets need `SO_UPDATE_ACCEPT_CONTEXT` before `shutdown`/graceful-close.

## Why now
The node-test harness plateaued (94/290 = 32.4%, spec 106): every remaining bucket of size
(`net`, `stream`, `http`, `child_process`, `worker_threads`) routes through **real async I/O**, which
the pure-std event loop cannot do (it can only `sleep` between timers). This cycle opens the I/O axis:
add **libxev** (Mitchell Hashimoto's Zig event loop — io_uring/kqueue/**IOCP on Windows**) as the
macrotask/I-O layer beneath the existing ECMA-262 microtask queue, and ship `net` (TCP) as its first
consumer. `stream` (proper Duplex) and `http`/`https` are the next cycles (108, 109).

## Charter / dependency decision (user-authorized 2026-06-20)
- **libxev becomes the FIRST external dependency** — this breaks the charter's historical "pure std"
  note. It is justified and explicitly authorized: a correct cross-platform async I/O loop
  (io_uring / kqueue / IOCP) cannot be hand-rolled in std without effectively re-implementing libuv.
  CLAUDE.md's "Active stack … pure std" line is amended to "pure std + libxev (host I/O only)".
- **Pin:** libxev commit `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`
  (hash `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F`). **VERIFIED** to compile, link,
  and run against the pinned **Zig 0.16.0** on this Windows machine (IOCP backend) before adopting.
- **Isolation invariant (unchanged):** libxev is HOST-only. It is reachable ONLY from the CLI host
  path (`runHost`/`evalHost` → `runEventLoop`). The Test262 engine surface
  (`evaluateWithLimit`/`evaluateAsyncTest`) never creates a loop or a socket → **0 Test262 regressions
  by construction.** The `ljs` module gains `xev` as an import, but no Test262-path code references it.

## ECMA-262 / Node scope
`net` is a **Node host API** (not ECMA-262) — squarely on the authorized Node host-runtime axis, not
the conformance axis. Governing reference: Node.js `net` docs (v22.16.0, the pinned node-test tag).

## Unit A — libxev wired into the build + the event loop
1. **build:** `zig fetch --save=xev` the pinned commit into `build.zig.zon`; expose `xev` as an import
   of the `ljs` module in `build.zig` so every consumer (exe, bench exe, test262 harness exe) links it.
   (libxev is inert unless a loop is created, so the harness exe carrying it is harmless.)
2. **loop integration (`host_timers.runEventLoop` + new `host_io.zig`):** lazily create one
   `xev.Loop` on the Interpreter the first time an I/O handle is opened (non-I/O scripts never touch
   libxev — zero overhead, preserves the existing pure-timer path bit-for-bit). Track `io_active`
   (count of live sockets/servers keeping the loop alive). New loop body:
   - drain nextTicks → drain microtasks → run one immediate (unchanged ordering).
   - **liveness:** continue while `timers` non-empty **OR** `io_active > 0` **OR** immediates pending.
   - **wait:** if `io_active == 0` keep the existing path exactly (find earliest timer; `sleepMs`) —
     **the timer tests must not regress.** If `io_active > 0`: arm a one-shot libxev wake-timer for
     `max(0, earliest_due − now)` (or no wake-timer when no JS timers pending), call
     `loop.run(.once)` (blocks until an I/O completion or the wake-timer fires), then **drain the
     microtask queue** before the next iteration (the integration rule: microtasks empty after EVERY
     libxev callback). JS-timer firing stays in our own min-deadline logic (identical semantics).
   - **Rule:** every libxev completion callback that invokes JS MUST be followed by a microtask drain
     before control returns to `loop.run` — enforced by always re-looping (top drains microtasks).

## Unit B — `net` module (`host_net.zig`) — `require('net')` / `require('node:net')`
TCP only this cycle (no Unix domain sockets / `net.connect('/path')`). `Socket` and `Server` are
**EventEmitters** (reuse `host_events`). Data delivered as a `Buffer` by default, or a decoded string
after `setEncoding`.
- **Client:** `net.connect(port[,host][,onConnect])` / `net.createConnection(...)` / `new net.Socket()`
  + `socket.connect(port[,host][,cb])`. Backed by `xev.TCP.connect`. Events: `'connect'`, `'data'`,
  `'end'`, `'close'`, `'error'`, `'timeout'` (best-effort). Methods: `write(data[,enc][,cb])`
  (`xev.TCP.write`; accepts string|Buffer|Uint8Array), `end([data][,enc][,cb])` (half-close via
  `xev.TCP.shutdown` then `close`), `setEncoding(enc)`, `setTimeout(ms[,cb])`, `setNoDelay`/
  `setKeepAlive` (accept + no-op/best-effort), `destroy([err])`, `pause()`/`resume()` (gate the read
  pump), `address()`, props `remoteAddress`/`remotePort`/`localAddress`/`localPort`/`bytesRead`/
  `bytesWritten`/`readyState`.
- **Server:** `net.createServer([opts,][connectionListener])` → `Server`. `listen(port[,host][,cb])`
  (bind+listen via `xev.TCP`, accept loop), events `'listening'`/`'connection'`(→`Socket`)/`'close'`/
  `'error'`; `close([cb])`, `address()` (`{port,family,address}`), `getConnections(cb)`,
  `ref()`/`unref()` (loop-liveness; first cut may no-op-but-accept), `maxConnections`.
- **statics/helpers:** `net.isIP(s)`/`isIPv4`/`isIPv6` (pure parse, no I/O), `net.Socket`, `net.Server`,
  `net.BlockedList`/`SocketAddress` deferred.
- **Read pump:** after `'connect'`/accept, queue an `xev.TCP.read` into a per-socket buffer; on each
  completion emit `'data'` (Buffer slice) and re-arm; `0`-length read / EOF → emit `'end'` (+`'close'`
  if writable side done); error → emit `'error'` + `'close'`. Respect `pause()`/`resume()`.

## Integration / dispatch
- New `NativeId` variants `net_method` (+ `socket_method`/`server_method` if a single one is awkward),
  dispatched additively in `interp_native.zig` (both switches, `=> unreachable` arm for the host id).
- Per-instance native state (the `xev.TCP` handle, read buffer, encoding, EventEmitter store) lives in
  a host-side registry keyed off a hidden own prop on the Socket/Server object (the established
  `"%...%"` pattern), since a `*xev.TCP` can't live inside a JS `Value`. Use a `std.AutoHashMap`
  (or an arena-allocated struct pointer stored as an integer handle prop).
- Registered as a core module in `host_require`'s registry (`net`, `node:net`).

## Files (keep each < ~2000 lines; split if needed)
- `src/host_io.zig` — the `xev.Loop` lifecycle + the libxev-aware wait used by `runEventLoop`
  (lazy-init, `io_active`, wake-timer, `runOnce`). New.
- `src/host_net.zig` — the `net` module surface (Socket/Server, statics). New.
- `src/host_timers.zig` — `runEventLoop` routes its idle-wait through `host_io` when `io_active > 0`.
- `src/runtime_types.zig` — `NativeId` net variant(s); the per-socket/per-server host state types.
- `src/interpreter.zig` — fields: `?*anyopaque`/typed loop handle, `io_active: usize`, the socket
  registry. (Thin; behaviour in host_io/host_net.)
- `src/interp_native.zig` — additive dispatch arms.
- `src/host_require.zig` — register `net`.
- `build.zig` / `build.zig.zon` — the dependency.
- `scripts/vendor-node-test.sh` — add `net stream http` to `MODULES` (re-vendor to measure).
- `CLAUDE.md` — amend the "pure std" note.

## Acceptance / gate
- **build / test / lint / bench green**; `zig build bench` shows **no ljs-vs-self regression** (the
  loop change must not slow the pure-timer path — re-bench `loop_mix`).
- **`language/` baseline: 0 regressions** (host-only; structural).
- **Functional (hand-written `ljs run`):** an echo server — `net.createServer` listens on an ephemeral
  port, a `net.connect` client writes `"ping"`, the server echoes, the client receives `"ping"` as a
  Buffer and both close cleanly; `net.isIP('1.2.3.4')===4`, `net.isIP('::1')===6`, `net.isIP('x')===0`.
- **Harness:** re-vendor with `net`/`stream`/`http` families, re-run `scripts/run-node-tests.sh --shim`;
  the **simpler `test-net-*` tests pass** (the stream-heavy ones wait for cycle 108). Record the new
  total. The net number being non-zero is the deliverable; a big jump is a 108/109 story.

## Out of scope (later cycles)
- `stream` (proper Readable/Writable/Duplex/Transform; make `Socket` a true Duplex) — **cycle 108**.
- `http`/`https` (parser, `IncomingMessage`/`ServerResponse`/`ClientRequest`) — **cycle 109**.
- Unix domain sockets, `dgram` (UDP), TLS, `cluster`, `worker_threads`, `child_process`.
- `ref()`/`unref()` precise loop-liveness accounting (accept the calls; refine later).
