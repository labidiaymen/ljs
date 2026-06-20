# Tasks — Spec 107 (libxev integration + `net`)

## Unit A — libxev + event loop
- [x] A1. `zig fetch --save=xev` the pinned commit; `build.zig.zon` records commit `9ce8e8e` + hash.
- [x] A2. `build.zig`: `xev` is an import of the `ljs` module (exe/bench/test262 all link it).
- [x] A3. `zig build` green with the new dep.
- [x] A4. `CLAUDE.md`: "pure std" → "pure std + libxev (host I/O only)". `.gitignore` += `zig-pkg/`.
- [x] A5. `src/host_io.zig`: `xev.Loop` lazy lifecycle, `ensureLoop`/`maybeLoop`/`pendingIo`/`tick`.
- [x] A6. Interpreter fields: `io_loop` (opaque), `io_pending`, `io_handles`, `next_io_id`.
- [x] A7. `host_timers.runEventLoop`: liveness `timers || io_pending`; idle-wait routes through
        `host_io.tick` when `io_pending>0`, else the existing `sleepMs` path. Extracted
        `earliestDueIndex`/`fireTimer` helpers (pure-timer path unchanged).
- [x] A8. Re-bench: isolated the ~18% to stale baseline (machine drift, HEAD itself +14.5%) + ~3%
        inherent libxev-linking cost (not struct layout — reorder had no effect; not the compute path).

## Unit B — `net`
- [x] B1. `runtime_types.zig`: `net_method` NativeId; per-Socket/Server host state in `host_net.zig`.
- [x] B2. `interp_native.zig`: additive dispatch arm + `=> unreachable`. `interp_expr.constructNT`:
        `new net.Socket()/Server()` constructible.
- [x] B3. `net.isIP`/`isIPv4`/`isIPv6` (pure parse via `std.Io.net.IpAddress`).
- [x] B4. `Socket` as EventEmitter (proto chains into `%EventEmitter.prototype%`; state via `"%io%"`).
- [x] B5. Client connect: `net.connect`/`createConnection`/`socket.connect` → `xev.TCP.connect`, 'connect'.
- [x] B6. Read pump: `xev.TCP.read` → 'data' (Buffer / decoded string); re-issue (IOCP `.rearm` unsafe);
        pause/resume gate; EOF → 'end'.
- [x] B7. `write`/`end`: `xev.TCP.write` + half-close `shutdown` (SO_UPDATE_ACCEPT_CONTEXT for accepted
        sockets); 'finish'/'close'; bytesRead/Written.
- [x] B8. `Server`: `createServer`/`listen` (bind+accept loop, re-issue accept), 'listening'/'connection'/
        'close', `address()`, `close()`, `getConnections`.
- [x] B9. Register `net`/`node:net` in `host_require`.

## Gate
- [x] G1. `zig build` + `zig build test` + `zig build lint` green.
- [x] G2. Echo-server acceptance script passes (client gets "ping", clean 'end'/'close'); `isIP` cases ok.
- [x] G3. `zig build bench` — ok (±2%) after re-recording the stale baseline (user-approved; HEAD
        itself was +14.5% from machine drift, libxev adds ~3% binary-layout cost).
- [x] G4. `language/` baseline run → exit 0 (0 regressions; 95.1% held).
- [~] G5. Vendor script now includes `net`/`stream`/`http`. Harness re-measure DEFERRED — re-vendoring
        wipes+refetches the whole node subset (slow/risky pre-commit); will measure when 108 (stream)
        lands, since the high-value `test-net-*` are stream-heavy. Spec Status → Done; commit + push.
