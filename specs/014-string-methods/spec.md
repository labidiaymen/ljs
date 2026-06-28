# Feature Specification: String Instance Methods

**Feature Branch**: `tjs-native` (milestone 014) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Add the common string instance methods on the `string` type. Builds on
the existing `.length` member and string-aware equality. Method calls lower to
inline expression blocks over the underlying byte slice; results are allocated
with the V1 page-allocator model (allocate-and-leak).

## Scope (V1)

Instance methods on a value of type `string`:

- `charAt(i: int): string` — single-character string, empty when out of range
- `charCodeAt(i: int): int` — byte code at the index, `-1` when out of range
- `indexOf(s: string): int` — first index of substring, `-1` when absent
- `includes(s: string): bool`
- `slice(start: int, end?: int): string`
- `substring(start: int, end?: int): string`
- `split(sep: string): string[]`
- `toUpperCase(): string`
- `toLowerCase(): string`
- `trim(): string`
- `startsWith(s: string): bool`
- `endsWith(s: string): bool`
- `repeat(n: int): string`
- `padStart(len: int, pad: string): string`
- `replace(from: string, to: string): string` — first occurrence only

`.length` on a string already works and is unchanged. V1 strings are byte
slices; indices and code points are byte-oriented.

Out of scope this cycle: full Unicode/grapheme handling, negative indices,
`replaceAll`, `padEnd`, `trimStart`/`trimEnd`, `match`/regular expressions,
`normalize`, locale-aware case mapping, and method chaining edge cases beyond the
uniform inline-block lowering.

## Requirements

- **FR-001**: On a value of type `string`, each listed method is callable with
  TypeScript call shape and yields the documented result type.
- **FR-002**: Return types are statically known: `split` -> `string[]`;
  `indexOf` / `charCodeAt` -> `int`; `includes` / `startsWith` / `endsWith` ->
  `bool`; `charAt` / `slice` / `substring` / `toUpperCase` / `toLowerCase` /
  `trim` / `repeat` / `padStart` / `replace` -> `string`.
- **FR-003**: Each `string`-typed argument must be assignable to `string`; each
  index/count argument must be an integer (`int`/`i64`). A mismatched argument
  type reports `E_TYPE_MISMATCH`.
- **FR-004**: A wrong argument count reports `E_ARG_COUNT`. Optional `end`
  arguments (`slice`, `substring`) accept zero or one trailing integer.
- **FR-005**: Calling an unknown method on a string reports `E_TYPE_MISMATCH`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: A program exercising each method compiles and the produced native
  binary prints the expected results.
- **SC-002**: A mismatched argument type and a wrong argument count each fail
  before native build.
- **SC-003**: `zig build conformance` passes with the feature 014 manifest, and
  the whole suite stays green.

## Notes

String methods reuse the existing method-call AST node and dispatch on a
`string` receiver alongside the shipped array-method path. Each method lowers to
an inline `blk:` expression over the byte slice using the Zig standard library
(`std.mem`, `std.ascii`) behind the scenes; the generated backend stays
invisible in user-facing text.
