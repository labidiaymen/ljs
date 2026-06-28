# Implementation Plan: By-Reference Parameters (`Ref<T>`)

## Approach

A `Ref<T>` parameter type-checks as its inner type `T` but lowers to a single Zig
pointer `*T`. The element type is unchanged; only the parameter's by-reference-ness
is added. This reuses the existing class-by-pointer lowering pattern (a class
instance is already `*Name`): a record `Ref<Counter>` becomes `*Counter`, and
field access/assignment work via Zig's single-pointer auto-deref. A scalar
`Ref<int>` becomes `*i32`, with explicit `.*` on reads and assignments.

`Ref` is a reserved built-in marker. The parameter-annotation resolver matches
`Ref<...>` **before** the generics machinery (feature 016) can treat `Ref` as a
user generic, so `Ref` is never monomorphized.

## Pieces

1. **AST** (`src/lumen_ast.zig`)
   - `FunctionParam`: add `is_ref` and `ref_scalar` flags.
   - `Expr.var_ref`: add `deref` (scalar ref read emits `name.*`).
   - `Assign`: add `deref` (scalar ref write emits `name.* = ...`).
   - `Expr.call`: add `ref_args: []bool` (mark which args take `&`).

2. **Types** (`src/lumen_types.zig`)
   - `refZigName(inner)` → `*<zigName(inner)>`.
   - `isRefAllowed(t)` / `isRefScalar(t)` classify legal inner types.

3. **Checker** (`src/lumen_check.zig`)
   - `refInner(annotation)`: detect `Ref<T>`, return the inner annotation.
   - `resolveParam`: intercept `Ref<T>` for function/method params; validate the
     inner type (`E_REF_TARGET`); set `is_ref`/`ref_scalar`; `checked_type = T`.
   - Reject `Ref<T>` on constructor params (`E_REF_TARGET`) and extern params
     (`E_FFI_TYPE`).
   - Bind ref params into scope with `is_ref`/`ref_scalar`; propagate `deref`
     onto var-ref reads and assignments of scalar ref params.
   - Allow field writes on a record `Ref<T>` parameter (path rooted in a ref
     binding), validating the record field type.
   - At call sites of user functions, build `ref_args`, require each ref argument
     to be an addressable, mutable lvalue (`E_REF_ARG`), and force the root
     variable to emit as a mutable `var`.

4. **Emitter** (`src/lumen_compiler.zig`)
   - Function and method param emit: `*T` for ref params.
   - Scalar ref var-ref read: append `.*`.
   - Scalar ref assignment: assign through `name.*`.
   - Call site: emit `&arg` for `ref_args[i]`.

## Verification

- `zig build` clean.
- Compile and run the valid examples with `./zig-out/bin/lumen compile`, confirm
  the caller observes the mutation.
- Compile the invalid examples, confirm the expected diagnostics.
- `zig build conformance` stays green including the four new cases.
