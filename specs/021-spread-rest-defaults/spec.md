# Spec: Spread, Rest, and Default Parameters

## Goal

Extend the Lumen TypeScript-syntax surface with three related ergonomics:

1. **Default parameter values** — `function f(x: int = 0)`. A trailing parameter
   may declare a default value used when the call omits it. Once a parameter has
   a default, every following non-rest parameter must also have one.
2. **Rest parameters** — `function f(...xs: T[])`. A final parameter prefixed
   with `...` collects all trailing arguments into an array.
3. **Spread** in three positions:
   - call arguments feeding a rest parameter: `f(...arr)`, `f(a, ...arr, b)`;
   - array literals: `[...a, x, ...b]`;
   - object literals: `{ ...src, key: value }`.

## Surface Rules

- A rest parameter must be the last parameter and must be array-typed.
- A default value must be assignable to its parameter's declared type.
- A spread call argument (`...src`) is only valid when it lands in a rest
  parameter slot; `src` must be an array assignable to the rest array type.
- In an array literal, each `...src` element must be an array whose element type
  matches the literal's element type.
- In an object literal, a single `...src` spread supplies any fields not written
  explicitly; `src` must be a record assignable to the target type. Explicit
  fields override spread-supplied ones.

## Diagnostics

- `E_TYPE_MISMATCH` — default value, spread source, or spread element type does
  not match the expected type.
- `E_ARG_COUNT` — fewer arguments than required, or too many for a non-rest
  signature.
- `E_REQUIRED_AFTER_OPTIONAL` — a required parameter follows a defaulted one.
- `E_REST_NOT_LAST` / `E_REST_NOT_ARRAY` — malformed rest parameter.
- `E_SPREAD_TARGET` — a spread argument does not feed a rest parameter.

## Out of Scope (V1)

- Spread arguments distributed across fixed parameters (needs tuple typing).
- Rest/default parameters in arrow-function expressions.
- Object spread merging across differing record types.
