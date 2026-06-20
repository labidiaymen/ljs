# Tasks — Spec 103 Node core modules wave 1

- [x] Unit A — `events`/EventEmitter (`host_events.zig`): on/once/off/emit/listeners/listenerCount/
      eventNames/prepend*/setMaxListeners; error-with-no-listener throws; new-able ctor. require('events').
- [x] Unit B — `util` (`host_util.zig`): format/inspect/promisify/callbackify/inherits/deprecate/
      isDeepStrictEqual/types.*. require('util').
- [x] Unit C — WHATWG `URL`/`URLSearchParams` + `TextEncoder`/`TextDecoder` (`host_url.zig`): globals
      via host_setup + require('url').
- [x] Unit D — `Buffer` expansion (`host_buffer.zig` + `host_buffer_rw.zig`): full read/write numeric
      matrix (Int/UInt 8/16/32 LE·BE, Float/Double) + indexOf/lastIndexOf/includes/fill/copy/compare/
      Buffer.compare/swap16/32.
- [x] Integration: 4 parallel worktree agents → sequential squash-merge; additive conflicts (NativeId,
      interp_native dispatch, host_require registry, constructNT) unioned by hand.
- [x] Gate: build/test/lint/bench GREEN; all 4 verified together; language baseline (host-only → 0 regr).
