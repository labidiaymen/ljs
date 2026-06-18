# Tasks — 081

- [x] Histogram `statements/class` + `expressions/class` failures; pick shared root causes.
- [x] T1: Derived-ctor non-object/non-undefined return → TypeError (`finishCtorReturn`).
- [x] T2: Lock ctor `prototype` own property to {writable:false, enumerable:false, configurable:false}.
- [x] T3: Static `prototype`-keyed element → TypeError (`staticPrototypeKeyError` + 3 call-sites).
- [x] Minimal repros verified (return override base/derived; prototype attrs; static get/set/method/field/computed; instance prototype key legal).
- [x] `zig build` / `zig build test` / `zig build lint` green.
- [x] class suites: statements +32 (8067→8099), expressions +2 (7596→7598), 0 in-suite regressions.
- [x] Full `language/` tree: 0 regressions vs `baseline/language.json` (conformance: ok; 39801/44475 = 89.5%).
- [x] `zig build bench` green (perf: ok, no ljs-vs-self regression).
- [x] Commit to worktree branch (no push).
