# Feature Specification: `test(...)` function form & `expect().toBe()`

**Feature Branch**: `tjs-native` (milestone 028) | **Created**: 2026-06-28 |
**Status**: Implemented

**Input**: Feature 008 introduced tests as a custom block — `test "name" { ... }`
— which `tsc` cannot parse. Every JS test runner (Jest, Vitest, `node:test`,
Deno, Bun) spells a test as a *function call*:

```ts
test("name", () => {
  expect(actual).toBe(expected);
});
```

That spelling is valid TypeScript, instantly familiar, and `tsc`-clean. Add it as
the preferred surface; keep the 008 block form working unchanged as an alias.

## Surface

The conventional function form declares a named test whose body is the arrow
callback:

```ts
test("add sums integers", () => {
  expect(add(2, 3)).toBe(5);
  expect(add(2, 3) == 5);
});
```

Inside a test body, two assertion shapes are supported:

- **Boolean** — `expect(cond)` asserts a boolean condition (the 008 form, kept
  working in both surfaces).
- **Matcher** — `expect(actual).toBe(expected)` asserts strict equality.
  `expect(actual).toEqual(expected)` is a strict-equality alias of `.toBe` for V1
  scalar and string values. Both operands must share a type.

The legacy block form remains valid and lowers identically:

```ts
test "add sums integers" {
  expect(add(2, 3) == 5);
}
```

Both forms run under `lumen test <file>` via `zig test`, which discovers and runs
the lowered test blocks and exits non-zero if any test fails. As in 008, test
declarations are inert under `lumen compile` (the executable build ignores them),
and tests are stripped from imported modules.

## Requirements

- **FR-001**: `test("name", () => { ...statements... });` declares a named test
  at the top level, equivalent to `test "name" { ... }`. `test` remains usable as
  an ordinary identifier where not immediately followed by a string or `(`.
- **FR-002**: `expect(actual).toBe(expected)` asserts strict equality inside a
  test; mismatched operand types report `E_TYPE_MISMATCH`. `expect(actual).toEqual(expected)`
  behaves identically for V1 values. `expect` outside a test is rejected.
- **FR-003**: The boolean form `expect(cond)` keeps working in both surfaces; a
  non-boolean argument reports `E_TYPE_MISMATCH` (008 behavior preserved).
- **FR-004**: `lumen test <file>` compiles and runs the tests via `zig test`,
  exiting non-zero if any test fails. The form (function vs block) is invisible to
  the runner.
- **FR-005**: An unknown matcher (`expect(x).toFoo(y)`) is rejected at parse time.

## Success Criteria

- **SC-001**: A file using the `test(...)` form with passing `expect().toBe()`
  assertions exits 0 under `lumen test`.
- **SC-002**: A failing `expect().toBe()` exits non-zero under `lumen test`.
- **SC-003**: A `test(...)` matcher with mismatched operand types fails to
  compile with `E_TYPE_MISMATCH`.
- **SC-004**: The 008 block form (`test "…" { … }`) and its conformance stay
  green; `test("x", () => { expect(1).toBe(1); })` type-checks under `tsc` with
  the ambient `lumen.d.ts`.

## Deferred

- Matchers beyond `.toBe` / `.toEqual` (`.toBeTruthy`, `.toContain`,
  `.not.*`, `.toThrow`, deep structural equality for objects/arrays).
- Async test callbacks (`test("x", async () => { ... })`).
- Per-test hooks (`beforeEach` / `afterEach`) and `describe` grouping.
