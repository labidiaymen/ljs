# Feature Specification: `declare function` for FFI

**Feature Branch**: `main` (milestone 025) | **Status**: Draft

**Input**: The C FFI (feature 009, extended by 023/024) declares an externally
provided function with `extern function name(params): R;`. That spelling is not
valid TypeScript — `tsc` rejects it as a parse error — so a Lumen FFI header
cannot be type-checked or shared as ordinary TypeScript. TypeScript already has
a spelling that means exactly this: an ambient `declare function name(params): R;`
declaration (a function with no body, provided externally). This feature accepts
`declare function` as a first-class FFI declaration form, identical in every way
to `extern function`, and makes it the preferred spelling.

## Scope

- Accept `declare function NAME(params): RetType;` as an FFI declaration.
- It lowers identically to `extern function`: the same external C-ABI prototype,
  the same `// @link <lib>` / `--link` handling, and the same scalar/string
  marshalling rules (features 009 and 023) and `Ref<T>` rules (feature 024).
- `extern function` remains a supported alias and is unchanged.

Out of scope: any change to FFI type rules, string marshalling, `Ref<T>`, or the
linking mechanism. This feature is purely an additional, TypeScript-valid
spelling of the same declaration.

## User Scenarios

### Declare and call a C function (P1)

```ts
// @link m
declare function pow(base: number, exp: number): number;
declare function sqrt(x: number): number;

console.log(sqrt(pow(3.0, 2.0) + pow(4.0, 2.0)));   // 5
```

**Independent test**: a program using `declare function` against libm (and
against a locally compiled C shim) compiles, links, runs, and prints the
expected output.

## Requirements

- **FR-001**: `declare function NAME(params): RetType;` MUST declare an external
  C-ABI function, identical to `extern function NAME(params): RetType;`.
- **FR-002**: A `declare function` declaration MUST honour `// @link <lib>` source
  pragmas and the `--link <lib>` flag exactly as `extern function` does.
- **FR-003**: A `declare function` declaration MUST apply the same FFI
  marshalling and type rules as `extern function` (scalars, `string` per 023,
  `Ref<T>` per 024); the same disallowed types MUST still report `E_FFI_TYPE`.
- **FR-004**: `extern function` MUST keep working as an alias with unchanged
  behaviour.

## Diagnostics

Reuses `E_FFI_TYPE`; no new diagnostics.

## Success Criteria

- **SC-001**: A program declaring `declare function pow/sqrt` with `// @link m`
  compiles, links, runs, and prints `5` then `1024`.
- **SC-002**: A program declaring `declare function shout(s: string): string`
  against a local C shim round-trips a string and prints the transformed text.
- **SC-003**: A `declare function` with a disallowed FFI parameter type (e.g.
  `int[]`) still reports `E_FFI_TYPE`.
- **SC-004**: Existing `extern function` examples and conformance cases (009/023)
  stay green.

## TypeScript-validity note

`declare function` is the reason for this feature: it parses cleanly under `tsc`
as an ambient declaration, so a Lumen FFI header can be shared as ordinary
TypeScript. User-facing docs prefer `declare function`; `extern function` is kept
as a legacy alias.
