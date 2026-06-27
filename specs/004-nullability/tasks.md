# Tasks: Nullability

## Cycle 5: null/undefined + nullable types (P1)
- [x] C5.1 Add `optional`/`none` to `src/lumen_types.zig` (`same`, `zigName`).
- [x] C5.2 Add `null_lit` expr to `src/lumen_ast.zig`; parse `null`/`undefined`.
- [x] C5.3 `parseTypeAnnotation` accepts `T | null` / `T | undefined`.
- [x] C5.4 Checker maps nullable annotation → optional; absent assignable to
  optional; reject absent→non-optional.
- [x] C5.5 Emit `?T` binding type and `null` literal.
- [x] C5.6 Valid + invalid example + manifest; `zig build conformance`.

## Cycle 6: optional fields/params + ?? (P2)
- [x] C6.1 Parse optional `name?: T` on fields and params → optional type.
- [x] C6.2 Object literals may omit optional fields (emit `null`).
- [x] C6.3 Lex `??`; check `a ?? b`; emit `orelse`.
- [x] C6.4 Valid + invalid example + manifest; `zig build conformance`.

## Cycle 7: ?. + narrowing (P3)
- [x] C7.1 Lex `?.`; check/emit optional chaining on optional named values.
- [x] C7.2 Add `var_ref.unwrap`; narrowing stack for `if (x != null)` /
  `if (x == null) else`.
- [x] C7.3 Emit `.?` on narrowed refs; type narrowed refs as non-optional.
- [x] C7.4 Valid + invalid example + manifest; `zig build conformance`.
