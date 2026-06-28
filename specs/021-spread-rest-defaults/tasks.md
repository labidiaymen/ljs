# Tasks: Spread, Rest, and Default Parameters

## Slice 1: lexer + AST (P1)
- [x] T1.1 Lexer: add `op3` token for `...`.
- [x] T1.2 AST: `FunctionParam.is_rest`/`default`; `Expr.spread`;
  `Expr.array` struct with `elem_type`; `FieldInit.is_spread`.

## Slice 2: parser (P2)
- [x] T2.1 Parse rest params and default values in `parseParamList`.
- [x] T2.2 Parse `...` spread in array literals and call argument lists.
- [x] T2.3 Parse `...src` in object literals.

## Slice 3: checker (P3)
- [x] T3.1 `validateParamSignature` (rest last/array, required-after-optional).
- [x] T3.2 Default-value type-check in `checkFunctionBody`.
- [x] T3.3 `checkCallArgs` normalizes calls (defaults filled, rest collected,
  spread only into rest).
- [x] T3.4 Array-literal inference + assignability handle spread elements.
- [x] T3.5 Object-literal record assignment resolves `...src` field reads.

## Slice 4: emitter (P4)
- [x] T4.1 Array literal with spread lowers to runtime concat; plain literals
  unchanged.
- [x] T4.2 Confirm rest params emit as plain slice params.

## Slice 5: conformance (P5)
- [x] T5.1 Valid examples: default params, rest + spread call, array/object
  spread.
- [x] T5.2 Invalid examples: default/spread/array mismatches, required-after-
  optional, missing-required-arg.
- [x] T5.3 Manifest + wire into `build.zig`; `zig build conformance` green.
