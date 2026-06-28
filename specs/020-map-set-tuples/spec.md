# Feature Specification: Map, Set, and Tuples

**Feature Branch**: `tjs-native` (milestone 020) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Add the built-in generic container types `Map<K, V>` and `Set<T>`, plus
fixed-length tuple types `[A, B, ...]` with positional indexed access. These build
on the generics infrastructure from 016: they are concrete built-in types
parameterized by their element/key/value types and lower to ordinary
monomorphic Zig.

## Scope (V1)

- **`Map<K, V>`**: created with `new Map<K, V>()`. Instance API:
  - `set(key: K, value: V): void`
  - `get(key: K): V | null`
  - `has(key: K): bool`
  - `delete(key: K): bool`
  - `size` (property): `int`
  - `keys(): K[]`, `values(): V[]`
  - `forEach((value: V, key: K) => void): void`
- **`Set<T>`**: created with `new Set<T>()`. Instance API:
  - `add(value: T): void`
  - `has(value: T): bool`
  - `delete(value: T): bool`
  - `size` (property): `int`
  - `values(): T[]`
  - `forEach((value: T) => void): void`
- **Tuples `[A, B, ...]`**: a fixed-length, positionally-typed annotation. A tuple
  value is written as an array literal `[a, b]` in a context whose declared type
  is a tuple. Element `i` is read with `t[i]` for an integer-literal index `i`,
  yielding the type at that position.

`K`, `V`, `T`, and tuple element types are the existing V1 concrete types:
`int`/`i32`, `i64`, `number`/`f64`, `bool`, `string` (and named/record types as
values). Map keys and Set elements are scalar (`int`, `i64`, `number`, `bool`,
`string`) so equality is well-defined.

Out of scope this cycle: Map/Set constructor arguments (initial entries),
`Map`/`Set` iteration via `for-of`, `Map.entries()` (an array of tuples, which
the V1 type surface does not yet represent), spreading, `WeakMap`/`WeakSet`,
tuple destructuring, tuple methods, rest elements in tuples, and dynamic
(non-literal) tuple indices.

## Requirements

- **FR-001**: `new Map<K, V>()` produces a value of type `Map<K, V>`;
  `new Set<T>()` produces a value of type `Set<T>`. A wrong number of type
  arguments reports `E_TYPE_ARG_COUNT`; a constructor argument reports
  `E_ARG_COUNT`.
- **FR-002**: Each Map/Set method is callable with TypeScript call shape and
  yields the documented result type. `get` returns `V | null`. `size` is read as
  a property. The `forEach` callback type is checked against the documented
  signature.
- **FR-003**: A method argument whose type does not match the container's `K`,
  `V`, or `T` reports `E_TYPE_MISMATCH`. An unknown method reports
  `E_TYPE_MISMATCH`. A wrong argument count reports `E_ARG_COUNT`.
- **FR-004**: A tuple annotation `[A, B, ...]` is accepted anywhere a type
  annotation is accepted. An array literal assigned to a tuple-typed binding must
  have the matching length and each element must satisfy the type at that
  position, else `E_TYPE_MISMATCH` (length mismatch is `E_TYPE_MISMATCH`).
- **FR-005**: `t[i]` on a tuple with an integer-literal index `i` in range yields
  the element type at position `i`; an out-of-range literal index reports
  `E_TYPE_MISMATCH`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`, `E_TYPE_ARG_COUNT`.

## Success Criteria

- **SC-001**: Programs exercising Map (set/get/has/delete/size/keys/values/
  entries/forEach), Set (add/has/delete/size/values/forEach), and tuples
  (construction + indexed access) compile and the native binaries print the
  expected results.
- **SC-002**: A wrong key type, a wrong value type, a wrong Set element type, a
  bad tuple element, and a tuple length mismatch each fail before native build.
- **SC-003**: `zig build conformance` passes with the feature 020 manifest and
  all previously green cases stay green.

## Notes

Map and Set lower to a small generic Zig container emitted once in the program
prologue (`LumenMap(K, V)` / `LumenSet(T)`), instantiated per concrete
type-argument tuple. Instances are heap pointers, mirroring class instances.
String keys/elements use value equality; scalar keys use identity equality.
Tuples lower to a positional Zig struct with `@"0"`, `@"1"`, … fields. All
generated code is ordinary monomorphic Zig.
</content>
</invoke>
