# Tasks: FFI String Marshalling

- [ ] T1 Allow `string` in the FFI-type predicate (params + return) in
  src/lumen_check.zig; keep arrays/records/functions rejected with `E_FFI_TYPE`.
- [ ] T2 Emit `string` -> `[*:0]const u8` in extern prototype generation
  (src/lumen_compiler.zig).
- [ ] T3 Marshal a `string` argument: NUL-terminated temporary via
  `std.fmt.allocPrintZ(__alloc, ...)`, pass `.ptr`.
- [ ] T4 Marshal a `string` return: `std.mem.span` + `__alloc.dupe` into an owned
  Lumen string.
- [ ] T5 Add `specs/023-ffi-strings/examples/` with a self-contained C shim
  (`shim.c` + `demo.ts` + `build.sh`, mirroring examples/ffi-cpp); verify
  string-in/string-out runs and prints expected output.
- [ ] T6 Add invalid conformance cases (array arg, record arg -> `E_FFI_TYPE`)
  and wire `specs/023-ffi-strings/conformance/manifest.json` into build.zig.
- [ ] T7 Confirm `examples/ffi-cpp` still builds; run `zig build conformance`
  (must stay green).
