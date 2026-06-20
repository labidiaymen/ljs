# Tasks — Spec 088 Destructuring pristine-iterator guard

- [x] T1. `interp_destr.zig`: add `iterMethodIsNative(self, value, want)` — proto-chain `@@iterator`
      identity check against an intrinsic NativeId.
- [x] T2. Gate the array fast path on `iterMethodIsNative(value, .array_values)` and the string fast
      path on `.string_iterator`; else fall through to `getIterator`.
- [x] T3. Gate: `zig build` + `test` + `lint` + `bench`; full `language/` sweep.
      Measured: language 41,048 → 41,314 (+266), 92.3% → 92.9%, 0 regressions, 0 panics, bench ok.
