# Tasks — 082

- [x] Add `canonicalArrayIndex` + `orderedStringKeys` to `src/object.zig`.
- [x] Fix `enumerateKeys` (for-in) ordinary-object ordering.
- [x] Fix `ordinaryOwnKeys` ordinary-object ordering.
- [x] Add §7.3.25 `copyDataPropertiesExcluding` (order + symbols + array indices + throw propagation + exclusion set).
- [x] Route object-literal spread through the helper (propagate abrupt).
- [x] Route `bindPattern` BindingRestProperty through the helper; rest object proto = `%Object.prototype%`.
- [x] Route `assignPattern` AssignmentRestProperty through the helper; accumulate exclusions in the forward loop.
- [x] Verify minimal repros (for-in order, obj-rest-order, computed/non-string/symbol/skip-non-enumerable).
- [x] `zig build` / `zig build test` / `zig build lint` green.
- [x] Full `language/` baseline: 0 regressions ("conformance: ok (no regression vs baseline)").
- [x] `zig build bench`: no regression ("perf: ok").
- [x] Commit (worktree branch, author Aymen, no Claude attribution).
