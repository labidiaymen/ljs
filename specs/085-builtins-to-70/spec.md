# Spec 085 — Built-ins push to 70%

**Status:** In progress
**Goal:** raise `built-ins/` conformance from **53.4%** (25,111 / 46,981) to **≥70%** (~32,887) by
recovering the large method-family / missing-object pools — pure ECMAScript built-in library, in charter.

## Approach
Multi-cycle, parallel subagents on NON-OVERLAPPING files (each owns one `builtin_*.zig` + localized
wiring in `builtins.zig`/`interp_native.zig`). Integrate sequentially; after each cycle run the FULL
`built-ins/` sweep (0 panics required — the spec-083 lesson) + `language/` 0-regression + bench. Cap 4
concurrent agents. Auto-commit + push each passing cycle (autonomous mode).

## Target pools (recoverable; excludes the defer engines Temporal/Atomics/SharedArrayBuffer/ShadowRealm)
- **Wave 1:** Date (1,188, new `builtin_date.zig`), Object (1,173), Array (1,300), String (686).
- **Wave 2:** RegExp (2,088 — recover the non-`\p{}` portion + assess property escapes), Promise (624),
  Function (385), Iterator helpers (270).
- **Wave 3 (mop-up):** Error/NativeErrors (232), JSON (106), Proxy (129), Symbol (64), Map/Set (≈70),
  Math (48), WeakRef/FinalizationRegistry (152), DisposableStack ×2 (394), TypedArray edge cases.

## Out of scope
Temporal, Atomics, SharedArrayBuffer, ShadowRealm, Intl, the Uint8Array base64/hex proposal — large
separate engines / proposals, deferred.

## Success criteria
- `built-ins/` ≥ 70%; `language/` no regression (≥ 40,450); full sweep 0 panics; bench `perf: ok`.
- `baseline/builtins.json` updated to the new passing set at each cycle close.
