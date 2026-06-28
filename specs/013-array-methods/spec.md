# Feature Specification: Array Higher-Order Methods

**Feature Branch**: `tjs-native` (milestone 013) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Add the common array instance methods on typed arrays `T[]`. Builds on
shipped closures (006): callbacks are ordinary typed arrow functions / function
values, and element types flow through statically.

## Scope (V1)

Instance methods on a typed array value `T[]`:

- `map((x: T) => U): U[]`
- `filter((x: T) => bool): T[]`
- `forEach((x: T) => void): void`
- `reduce((acc: U, x: T) => U, init: U): U`
- `find((x: T) => bool): T | null`
- `some((x: T) => bool): bool`
- `every((x: T) => bool): bool`
- `indexOf(x: T): int`
- `includes(x: T): bool`
- `join(sep?: string): string`

Element types are checked statically: a callback whose parameter or return type
does not line up with the array's element type is a type error, as is a wrong
argument count or a mismatched `indexOf`/`includes` element.

Out of scope this cycle: the index/array extra callback parameters
(`(x, i, arr) => ...`), `reduce` without an initial value, `reduceRight`,
`sort`, `slice`, `concat`, `flatMap`, `findIndex`, `lastIndexOf`, and methods on
arrays of records / class instances (`T[]` here means a scalar element type:
`int`, `i64`, `number`, `bool`, `string`).

## Requirements

- **FR-001**: On a value of array type `T[]`, the methods above are callable with
  TypeScript call shape and yield the documented result type.
- **FR-002**: `map`/`filter`/`forEach`/`find`/`some`/`every` take a single
  callback. The callback's parameter type must accept `T`; `map`'s result
  element type is the callback's return type `U`; `filter`/`find` keep element
  type `T`; the boolean-callback methods require a `bool`-returning callback.
- **FR-003**: `reduce` takes `(callback, init)`; `init` determines the
  accumulator/result type `U`, and the callback must have type
  `(U, T) => U`.
- **FR-004**: `indexOf(x)` / `includes(x)` take a single value assignable to `T`
  and return `int` / `bool`; equality is value equality (string-aware).
- **FR-005**: `join(sep?)` takes an optional `string` separator (default `","`)
  and returns a `string`; each element is rendered with its natural text form.
- **FR-006**: A wrong argument count reports `E_ARG_COUNT`; a callback or value
  whose type does not match reports `E_TYPE_MISMATCH`. Calling an unknown method
  on an array reports `E_TYPE_MISMATCH`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: Programs using each method compile and the produced native binary
  prints the expected results.
- **SC-002**: A callback element-type mismatch, a wrong-typed `indexOf`/
  `includes` argument, and a wrong argument count each fail before native build.
- **SC-003**: `zig build conformance` passes with the feature 013 manifest.

## Notes

Method calls on arrays lower to inline expression blocks over the underlying
slice; callbacks are invoked through the existing uniform function-value
representation, so named functions, arrows, and capturing closures all work as
callbacks. Result arrays are allocated with the V1 page-allocator model
(allocate-and-leak); there is no in-place mutation of the receiver.
