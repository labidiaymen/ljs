# Implementation Plan: Map, Set, Tuples (020)

## Stack
Zig 0.16.0, existing Lumen compiler pipeline (lumen_lexer, lumen_ast,
lumen_types, lumen_check, lumen_compiler, lumen_diag, CLI lumen.zig).

## Types (lumen_types.zig)
- Add `Type` variants:
  - `map_type: *const MapType` where `MapType = struct { key: *const Type, value: *const Type }`
  - `set_type: *const Type` (element type)
  - `tuple_type: []const Type`
- Extend `same`, `mangle`, `zigName`, `toAnnotation` for the new variants.
- `zigName` lowers `map_type`/`set_type` to `*LumenMap_<k>_<v>` / `*LumenSet_<t>`
  (heap pointer), and `tuple_type` to a positional `struct { @"0": .., ... }`.

## Annotations (lumen_check.zig typeFromAnnotation)
- Parse `Map<K,V>` and `Set<T>` annotation strings into the new types (reuse
  `splitTypeArgs`); wrong arg count -> `E_TYPE_ARG_COUNT`.
- Parse `[A,B,...]` tuple annotations (top-level comma split inside brackets).

## Checker (lumen_check.zig)
- `new_expr`: special-case class names `Map` / `Set`: validate type-arg count and
  zero ctor args, return the container type. Record the concrete container type
  on the new_expr (via a new optional AST field) for emission.
- `method_call`: when receiver is `map_type` / `set_type`, dispatch to new
  `mapMethod` / `setMethod` checkers that validate arg types/counts and return
  result types; record method metadata for emission.
- `field` (`.size`): when receiver is `map_type`/`set_type`, return `.i32` and
  flag a `size` builtin.
- Tuple literal: when an array literal is checked against a tuple target type,
  validate length + per-position element types; record the tuple type for emit.
- Tuple index `t[i]`: integer-literal index in range -> element type.

## Emitter (lumen_compiler.zig)
- Prologue: emit a generic `fn LumenMap(comptime K, comptime V) type` and
  `fn LumenSet(comptime T) type` (string-aware eql/hash; insertion-ordered keys
  for deterministic iteration) when the program uses Map/Set.
- `new_expr` for Map/Set: emit `LumenMap(K,V).__init()` (heap-allocated pointer).
- `method_call` on container: emit `recv.set(...)`, `.get(...)` (returns `?V`),
  `.has`, `.delete`, `.size()`, `.keys()`, `.values()`, `.entries()`,
  `.forEach(cb)` lowering to the runtime helper, using the uniform function-value
  representation for callbacks.
- `.size` field -> `recv.size()`.
- Tuple literal -> `.{ .@"0" = a, .@"1" = b }` against the positional struct.
- Tuple index -> `t.@"0"` etc.

## Examples + conformance
- examples/valid: map-basics, set-basics, tuples.
- examples/invalid: map key/value type, set element type, tuple element, tuple
  length.
- conformance/manifest.json mirroring 013; wire `conformance_cmd_020` into
  build.zig.

## Verify
`zig build` then `zig build conformance` fully green including the new cases.
</content>
