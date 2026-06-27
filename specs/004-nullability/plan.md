# Implementation Plan: Nullability

**Branch**: `tjs-native` | **Spec**: [spec.md](./spec.md)

## Summary

First architecture-touching milestone. Adds an `optional` wrapper to the type
representation, a `none` type for the absent literal, the `??`/`?.` operators,
and a limited flow-sensitive narrowing pass for `if (x != null)`. Lowers to Zig
optionals (`?T`), `orelse`, and `.?` unwrap.

## Affected Modules

- `src/lumen_types.zig` — `optional: *const Type` and `none` variants; `same`,
  `zigName` updates; `optionalOf` is built in the checker (needs arena).
- `src/lumen_ast.zig` — `null_lit` expression; `var_ref.unwrap` flag for narrowed
  uses; `coalesce` (`??`) and optional-chain reuse of `field`.
- `src/lumen_lexer.zig` — `??` and `?.` tokens.
- `src/lumen_check.zig` — optional annotation parsing (`T | null`), null literal
  typing, `??`/`?.` checking, assignability of absent to optional, and the
  narrowing stack.
- `src/lumen_compiler.zig` — parse `null`/`undefined`/`??`/`?.`/optional `?`;
  emit `?T`, `null`, `orelse`, `.?` unwrap on narrowed refs.
- `build.zig` — wire the 004 manifest.

## Cycle Breakdown

### Cycle 5 — null/undefined + nullable types
Type `optional`/`none`; `null`/`undefined` literals; `parseTypeAnnotation`
captures `T | null`/`T | undefined`; checker maps that to an optional type;
absent assignable to optional; emit `?T` bindings and `null` literal.

### Cycle 6 — optional fields/params + `??`
`name?: T` on fields and params → optional; object literals may omit optional
fields (emit `null`); `??` operator (lexer `??`, checker present/else typing,
emit `orelse`).

### Cycle 7 — `?.` + narrowing
`?.` optional chaining on optional named values (emit `if (x) |v| v.f else
null`); flow narrowing for `if (x != null)` / `if (x == null) else`, marking
narrowed var_refs so they unwrap with `.?` and type as non-optional.

## Verification Per Cycle
`zig build`, valid + invalid example, `zig build conformance`.
