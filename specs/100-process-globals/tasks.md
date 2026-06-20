# Tasks — Spec 100 process + globals + nextTick

- [x] T1. `runtime_types.zig`: `NativeId.process_method` + `NextTickEntry` (re-export in object.zig).
- [x] T2. `interpreter.zig`: `next_tick_queue` + `host_cwd` fields.
- [x] T3. `host_setup.zig` (new): `HostCtx { argv, env_pairs, cwd, pid }`; `installHostGlobals` builds
      `process` + `global`; timer/console registration MOVED here from `builtins.zig`.
- [x] T4. `host_setup.processMethod` impls (cwd/exit/nextTick/stdout-stderr write) + `drainNextTicks`;
      `runEventLoop` drains nextTicks at the top of each turn (before `drainJobs`); `runHost` drains
      pre-loop.
- [x] T5. `interp_native.zig`: dispatch `.process_method` (+ second-switch unreachable arm).
- [x] T6. `builtins.zig`: timer/console registration removed (now host-only).
- [x] T7. `engine.runHost(ctx,out,err)` + new `evalHost` (host globals, no loop); `main.zig` builds the
      ctx (argv / `init.environ_map.iterator()` / `std.process.currentPathAlloc` / per-platform pid).
- [x] T8. Verified: `true win32 string`; nextTick→promise ordering (`sync,nt,p`); `process.env.PATH`
      non-empty; `global===globalThis`; `process.stdout.write`; `process.exit(3)` → exit 3, no "after".
- [x] T9. build/test/lint/bench GREEN; language baseline conformance: ok (42,308/95.1%, 0 regressions); built-ins 31,505/ok. Committed + pushed.
      31,505/ok); present at gate.
