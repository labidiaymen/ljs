# Tasks 075

- [x] Add `getOrInsert` helper in `builtin_collection.zig` (Map + WeakMap shared, `weak` gate).
- [x] Add `getOrInsertComputed` helper (IsCallable-before-lookup, canonical key to callback,
      re-resolve slot after callback, throw-leaves-unchanged).
- [x] Dispatch arms in `mapMethod` (weak=false) and `weakMapMethod` (weak=true).
- [x] `defineMethodLen` helper in `builtins.zig`; register the 4 methods with `length = 2`.
- [x] `zig build` green.
- [x] All four `prototype/getOrInsert*` directories 100% (142 tests).
- [x] `zig build test` / `zig build lint` / `zig build bench` green.
- [x] Zero language regressions vs baseline.
