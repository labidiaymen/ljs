# Plan: Spread, Rest, and Default Parameters

## Approach

Keep generated Zig simple by normalizing call sites at type-check time so the
emitter always sees a fixed-arity argument list.

### Lexer
- Add an `op3` token for `...` (three dots).

### AST
- `FunctionParam`: add `is_rest: bool` and `default: ?*Expr`.
- `Expr`: add `spread: *Expr` (a `...expr` element in an array literal or call
  argument list).
- `Expr.array` becomes `{ items: []*Expr, elem_type: ?Type }`; `elem_type` is
  filled when the literal needs runtime concatenation (any spread element, or an
  empty rest collection).
- `FieldInit`: add `is_spread` for object-literal `...src` entries.

### Parser
- `parseParamList` recognizes a leading `...` (rest) and a trailing `= expr`
  (default), enforcing that rest is last and rest has no default.
- Array literals and call argument lists parse elements via `parseSpreadOrExpr`.
- Object literals accept `...src` entries.

### Checker
- `declareFunction` validates the parameter signature (rest last/array,
  no required-after-optional) via `validateParamSignature`.
- `checkFunctionBody` type-checks each default value against its parameter type.
- `checkCallArgs` validates a call against a parameter list with defaults/rest,
  filling omitted trailing args with defaults and collecting the rest into an
  array literal node. Spread args are only allowed in the rest slot.
- Array-literal inference and array assignability treat `...src` as contributing
  the source array's element type.
- Object-literal assignment against a named record resolves `...src` by reading
  each unspecified field as `src.field`.

### Emitter
- Rest parameters need no special emission — they are ordinary slice-typed
  params, and call sites pass an array node.
- An array literal with `elem_type` set lowers to a runtime
  `std.mem.concat(page_allocator, ELEM, &.{ ... })`, wrapping plain entries as
  one-element slices and emitting spread sources directly. Without `elem_type`
  the existing comptime `&.{ ... }` literal is kept.
- Object spreads are erased by the checker (rewritten to per-field reads), so the
  object emitter is unchanged.

## Verification

- Scratch programs per feature compile and run.
- `examples/valid` (3) + `examples/invalid` (5) with a manifest mirroring 013.
- `zig build conformance` stays green including the new cases.
