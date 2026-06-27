# Feature Specification: C FFI (extern functions + linking)

**Feature Branch**: `tjs-native` (milestone 009) | **Created**: 2026-06-27 |
**Status**: Draft

**Input**: Let Lumen call native C-ABI libraries. Because Lumen lowers to Zig
(best-in-class C interop), this is mostly plumbing: declare an external function
signature, and tell the compiler which library/object to link.

C++ libraries are supported through a C-compatible (`extern "C"`) shim — Zig
links the C ABI, not the C++ mangled ABI.

## Requirements

- **FR-001**: `extern function name(p: T, ...): R;` declares an external C-ABI
  function. It has no body and is resolved at link time.
- **FR-002**: Parameter and return types MUST be C-safe scalars — `int`/`i32`,
  `i64`, `number`/`f64`, `bool` (and `void` for the return). Any other type
  reports `E_FFI_TYPE`.
- **FR-003**: An `extern` function is callable like any other function;
  argument count and types are checked against the declared signature.
- **FR-004**: A `// @link <lib>` pragma in the source, or a `--link <lib>` CLI
  flag, links a library. A bare name (`m`) becomes `-lm`; a path-like token
  (`./libfoo.a`, `geometry.o`) is linked verbatim.
- **FR-005**: The generated Zig emits `extern fn name(...) R;` and the linker
  flags are passed to `zig build-exe`.

### Diagnostics

- **E_FFI_TYPE**: An extern signature uses a non-C-safe parameter/return type.

## Success Criteria

- **SC-001**: A program declaring `extern function pow/sqrt` with `// @link m`
  compiles, links libm, and prints the computed results.
- **SC-002**: An extern signature with a non-scalar type fails with `E_FFI_TYPE`.
- **SC-003**: A C++ library exposed via `extern "C"` links and runs (see
  `examples/ffi-cpp/`).
- **SC-004**: `zig build conformance` passes with the feature 009 manifest.

## Notes

- This links **local/system** libraries; it is not a package manager and does
  not fetch remote packages, so it stays within the V1 "no remote packages"
  guardrail.
- String/pointer/struct marshaling across the C boundary is out of scope for
  V1; only scalar arguments are supported.
