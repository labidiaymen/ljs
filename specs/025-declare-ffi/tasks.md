# Tasks: `declare function` for FFI

- [x] T1 Dispatch the `declare` keyword to `parseExternDecl` in `parseStmt`.
- [x] T2 Generalize `parseExternDecl` to consume `extern` or `declare`, then
      require `function`; keep all downstream lowering identical.
- [x] T3 Add a VALID conformance case: `declare function pow/sqrt` with
      `// @link m` (compile-run, expects `5\n1024`).
- [x] T4 Add an INVALID conformance case: `declare function f(xs: int[])`
      reports `E_FFI_TYPE`.
- [x] T5 Add a string-marshalling demo (`declare function shout(s: string)`)
      with a local C shim + build.sh (manual run, mirrors 023).
- [x] T6 Wire `specs/025-declare-ffi/conformance/manifest.json` into `build.zig`.
- [x] T7 Migrate examples/website/README to the `declare function` spelling
      (keep `extern` documented as an alias); re-verify they compile/run.
- [x] T8 `zig build` clean; `zig build conformance` green.
