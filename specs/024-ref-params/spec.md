# Feature Specification: By-Reference Parameters (`Ref<T>`)

**Feature Branch**: `tjs-native` (milestone 024) | **Created**: 2026-06-28 |
**Status**: Implemented

**Input**: Add by-reference function parameters spelled with a TypeScript-valid
`Ref<T>` type. A parameter typed `Ref<T>` is passed by reference: the callee can
mutate it and the caller observes the change. Call sites stay plain (no `&`/`ref`
marker) — the compiler inserts the address-of automatically.

## Surface

```ts
type Counter = { n: int };

function bump(c: Ref<Counter>): void {
  c.n += 1;            // mutate a field of the record through the reference
}

let ct: Counter = { n: 5 };
bump(ct);              // plain call; the compiler passes ct by reference
console.log(ct.n);     // 6 — the caller observes the mutation
```

An out-style scalar parameter:

```ts
function inc(x: Ref<int>): void {
  x = x + 1;           // assignment is visible to the caller
}

let n = 0;
inc(n);                // n becomes 1
```

`Ref<T>` is valid TypeScript syntax (it is just a generic type reference), so
`tsc`/`eslint` accept `.ts` sources unchanged. The repo root ships an ambient
declaration `lumen.d.ts` containing `type Ref<T> = T;` so plain TypeScript
tooling treats `Ref<T>` as an identity alias. The Lumen compiler treats `Ref`
specially: it is a reserved built-in marker, intercepted before the generics
machinery so it is never monomorphized as a user generic.

## Semantics (V1)

- `Ref<T>` is permitted for **value types**: records/interfaces, scalars
  (`int`/`i32`, `i64`, `number`/`f64`, `bool`), unions, enums, and tuples.
- `Ref<T>` is **rejected** for types that are already reference-like:
  - **classes** (already passed by reference) — diagnostic `E_REF_TARGET`;
  - **arrays** and **strings** (already slices) — diagnostic `E_REF_TARGET`;
  - maps, sets, and promises (already heap pointers) — diagnostic `E_REF_TARGET`.
- Inside the body, a `Ref<T>` parameter type-checks exactly as `T`: field access,
  arithmetic, and assignment behave as if the parameter had type `T`. Only the
  by-reference-ness differs.
- A record `Ref<T>` parameter is **mutable through the reference**: writing one of
  its fields (`c.n = ...`, `c.n += 1`) is allowed, unlike a plain V1 record
  binding (which is immutable).
- At a call site, a `Ref<T>` argument MUST be an **addressable, mutable lvalue**:
  a variable, or a field path rooted in one (`obj.field`, `obj.a.b`). Passing a
  literal, a temporary, an arbitrary expression, or an immutable (`const`)
  binding is an error — diagnostic `E_REF_ARG`.
- `Ref<T>` is not allowed on constructor parameters (they become fields) nor on
  `extern function` parameters (not part of the C ABI). Nor as a rest parameter.

## Diagnostics

- `E_REF_TARGET` — `Ref<T>` used over a non-value (class/array/string/etc.) type,
  on a constructor parameter, or as a rest parameter.
- `E_REF_ARG` — a `Ref<T>` argument is not an addressable, mutable lvalue.
- `E_FFI_TYPE` — `Ref<T>` used on an `extern function` parameter.

## Out of Scope (V1)

- `Ref<T>` over class, array, string, map, set, or promise types.
- Returning a `Ref<T>`, storing a `Ref<T>` in a field or local, or `Ref<Ref<T>>`.
- Constructor or extern by-reference parameters.

## Acceptance

- Mutating a record field through a `Ref<T>` parameter is observable in the
  caller (`record-by-ref.ts`).
- A scalar `Ref<int>` out-parameter assignment is observable in the caller
  (`scalar-out-param.ts`).
- `Ref<Class>` is rejected with `E_REF_TARGET` (`ref-on-class.ts`).
- A non-lvalue `Ref<T>` argument is rejected with `E_REF_ARG`
  (`ref-non-lvalue.ts`).
- User-facing text and diagnostics never mention the generated Zig.
