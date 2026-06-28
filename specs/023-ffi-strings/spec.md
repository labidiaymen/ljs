# Feature Specification: FFI String Marshalling

**Feature Branch**: `main` (milestone 023) | **Status**: Draft

**Input**: Extend the existing C FFI (feature 009) so an `extern function` may take
and return `string`. Scalar-only FFI (`int`/`i64`/`number`/`bool`) cannot pass
text, which blocks any real C library binding (passing a path, a SQL query, a
script source) and blocks reading text back out (the value-export direction).
This is the enabler for community library bindings such as `quickjs`.

## Scope

- `string` as an `extern function` parameter, marshalled to a NUL-terminated
  C `const char*` (UTF-8).
- `string` as an `extern function` return type, marshalled from a C
  `const char*` into an owned Lumen `string` (copied at the call boundary).
- Opaque native handles continue to be modelled as `i64` by convention (the C
  shim keeps real pointers in an integer handle table). No new pointer type.

Out of scope (future): structs/records by value, arrays across FFI, C callbacks
into Lumen, automatic free of malloc'd return strings (ownership is by
convention, see below), `null` C strings.

## User Scenarios

### Pass and return text across FFI (P1)

```ts
// @link ./shim.o
extern function shout(s: string): string;   // C: const char* shout(const char*)

console.log(shout("hi"));   // HI
```

**Independent test**: a self-contained C shim (compiled locally, like
`examples/ffi-cpp`) round-trips a string through Lumen and prints the result.

## Requirements

- **FR-001**: An `extern function` parameter typed `string` MUST be passed to C
  as a NUL-terminated UTF-8 `const char*`.
- **FR-002**: An `extern function` whose return type is `string` MUST copy the
  returned `const char*` into a freshly owned Lumen `string` at the call site;
  the Lumen value is independent of the C buffer afterwards.
- **FR-003**: A `string` return value MUST be treated as valid only at the moment
  of return; the binding copies immediately. (Ownership convention: if the C side
  malloc'd it, freeing is the C shim's responsibility, e.g. a static/reused
  buffer or a paired free function — Lumen does not free it.)
- **FR-004**: Non-scalar, non-string FFI parameter/return types (arrays, records,
  functions) MUST still report `E_FFI_TYPE`.
- **FR-005**: All existing scalar FFI behaviour (feature 009) MUST be unchanged.

## Diagnostics

Reuses `E_FFI_TYPE` (now permits `string` in addition to the scalars).

## Success Criteria

- **SC-001**: A program calling an `extern function (s: string): string` against a
  local C shim compiles, links, runs, and prints the transformed text.
- **SC-002**: Passing an array/record to an `extern function` still fails with
  `E_FFI_TYPE`.
- **SC-003**: Existing FFI examples (`examples/ffi-cpp`) still build and run.

## Security / safety note

FFI string returns assume the C function returns a pointer valid at return time.
The binding copies it once. Bindings that return malloc'd memory must document
their free convention; Lumen will not free FFI-returned pointers.
