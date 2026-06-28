# Implementation Plan: String Instance Methods (014)

**Branch**: `tjs-native` | **Spec**: [spec.md](./spec.md)

## Summary

Add string instance methods on the `string` type, mirroring the shipped
array-method slice (013). The checker gains a `stringMethod` branch that validates
arguments and computes result types; the emitter gains an `emitStringMethod`
lowering that produces inline expression blocks over the byte slice. Routing
reuses the existing `method_call` AST node with a new `string_method` flag so the
emitter can distinguish string receivers from array receivers.

## Technical Context

- **Checker**: `src/lumen_check.zig` — dispatch in `exprType` `.method_call`
  arm; new `stringMethod` helper next to `arrayMethod`.
- **AST**: `src/lumen_ast.zig` — add `string_method: bool = false` and reuse
  `array_result_type` to carry the checked result type.
- **Emitter**: `src/lumen_compiler.zig` — `emitStringMethod` next to
  `emitArrayMethod`; route in the `.method_call` emit arm.
- **Types**: `src/lumen_types.zig` — `arrayOf(.string)` already yields
  `string_array` for `split`.

## Lowering

Each method lowers to `(__sm{n}: { const __s = <recv>; ... break :__sm{n} <v>; })`
with a unique monotonic label, allocating result strings/arrays with the page
allocator (allocate-and-leak, matching 013). Helpers used: `std.mem.indexOf`,
`std.mem.startsWith`, `std.mem.endsWith`, `std.mem.trim`, `std.ascii` case maps.

## Milestone Strategy

1. AST flag + checker dispatch and per-method validation.
2. Emitter lowering for each method.
3. Valid example program (verify stdout) + invalid examples.
4. Manifest + wire `conformance_cmd_014` into `build.zig`; keep suite green.
