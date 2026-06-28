# Implementation Plan: FFI String Marshalling

**Branch**: `main` | **Spec**: [spec.md](./spec.md)

## Summary

Feature 009 lowers `extern function` declarations to Zig `extern fn` prototypes
and emits direct calls. Today only scalar types pass the FFI type check. This
adds `string` as an allowed FFI type and emits the marshalling glue: a
NUL-terminated copy on the way in, an owned copy on the way out. The C side sees
plain `const char*`; the Lumen side keeps its normal `string`.

## Affected code

- `src/lumen_check.zig` — the FFI type validator (the path that emits
  `E_FFI_TYPE`): permit `string` for params and return type; keep rejecting
  arrays/records/function types.
- `src/lumen_compiler.zig` — extern prototype emission and call emission:
  - prototype: a `string` param becomes Zig `[*:0]const u8`; a `string` return
    becomes `[*:0]const u8`.
  - call site, string arg: emit a NUL-terminated temporary,
    `const __s_N = try std.fmt.allocPrintZ(__alloc, "{s}", .{ <arg> });` and pass
    `__s_N.ptr` (or `__s_N`).
  - call site, string return: wrap the raw pointer,
    `blk: { const __r = <call>; break :blk try __alloc.dupe(u8, std.mem.span(__r)); }`
    yielding an owned `[]const u8` Lumen string.
- `src/lumen_types.zig` — only if the FFI-permitted-type predicate lives here.

## Approach

1. Extend the FFI-type predicate to accept `.string` for both directions.
2. In extern prototype emission, map `string` -> `[*:0]const u8`.
3. In call emission, special-case `string` arguments (NUL-terminate) and a
   `string` result (span + dupe into the arena/page allocator already used for
   I/O plumbing — reuse `__alloc`).
4. Leave scalars exactly as-is.

## Verification

- A self-contained C shim under `specs/023-ffi-strings/examples/` (compiled by a
  small build step or the example's own `build.sh`, mirroring `examples/ffi-cpp`)
  exercises string-in/string-out and is run manually / in a non-offline check.
- Offline conformance cases (no external linking): invalid programs that pass an
  array and a record to an `extern function` and expect `E_FFI_TYPE`; these run
  in the standard `zig build conformance` gate.
- `examples/ffi-cpp` still builds.

## Risks

- Lifetime of returned `const char*` (mitigated: copy immediately; document the
  free convention).
- Encoding: assumes UTF-8 both directions (Lumen strings are UTF-8).
- Conformance can't link arbitrary C in the offline gate, so the positive case is
  example-based; keep the negative (type-reject) cases in the offline suite.
