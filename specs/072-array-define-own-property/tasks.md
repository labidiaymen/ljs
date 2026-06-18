# Tasks 072

- [x] Add `arrayIndex` (IsArrayIndex canonical predicate) in `builtin_object.zig`.
- [x] Implement `arrayDefineIndex` (§10.4.2.1) over the dense/sparse element store + `[[Length]]`.
- [x] Route `objectDefineProperty` array `length`/index through the array-aware path.
- [x] Route `objectDefineProperties` array `length`/index (was a plain `defineProperty`).
- [x] `objectGetOwnPropertyDescriptor`: property-map-first for array indices (non-default attrs).
- [x] `reflectSet`: §10.1.9 receiver redirection (string + symbol), non-object receiver → false.
- [x] `Reflect.defineProperty`: integer-index routing into `arrayDefineIndex`.
- [x] Verify: `zig build` / `zig build test` / `zig build lint` green.
- [x] Conformance: Object 5407→5535, Reflect 248→260, 0 regressions within those areas.
- [x] Gate: full `test/language` baseline = 0 regressions (44475 tests, 90.3%); `zig build bench` no regression.
