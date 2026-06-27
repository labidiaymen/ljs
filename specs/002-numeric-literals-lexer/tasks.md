# Tasks: Numeric Literals And Lexer Completeness

**Input**: `spec.md`, `plan.md`

Four cycles. Each cycle is independently shippable and ends with `zig build` +
`zig build conformance`.

## Cycle 1: Float Literals (P1)

- [x] C1.1 Add `flt: f64` token to `src/lumen_lexer.zig` and lex
  `<digits>.<digits>` with optional `e`/`E` exponent and sign.
- [x] C1.2 Add `float: f64` expression node to `src/lumen_ast.zig`.
- [x] C1.3 Map `inferExprType(.float) => f64` in `src/lumen_types.zig`.
- [x] C1.4 Type the float node and reject float→int assignment with
  `E_TYPE_MISMATCH` in `src/lumen_check.zig`.
- [x] C1.5 Parse `flt` into `.float` and emit float formatting in
  `src/lumen_compiler.zig`.
- [x] C1.6 Add valid float example + invalid float→int example + manifest cases.
- [x] C1.7 `zig build` and `zig build conformance` pass.

## Cycle 2: Integer Bases And Separators (P2)

- [x] C2.1 Lex `0x`/`0X`, `0o`/`0O`, `0b`/`0B` integer literals in
  `src/lumen_lexer.zig`.
- [x] C2.2 Allow `_` digit separators in integer and float literals.
- [x] C2.3 Add `E_INVALID_NUMBER` to `src/lumen_diag.zig` and report it for a
  base prefix with no digits.
- [x] C2.4 Add valid bases/separators example + invalid malformed-literal
  example + manifest cases.
- [x] C2.5 `zig build` and `zig build conformance` pass.

## Cycle 3: Block Comments (P3)

- [x] C3.1 Skip `/* ... */` block comments in `src/lumen_lexer.zig`, tracking
  embedded newlines for line/column accuracy.
- [x] C3.2 Add `E_UNTERMINATED_COMMENT` to `src/lumen_diag.zig` and report it at
  EOF inside an open block comment.
- [x] C3.3 Add valid multi-line block-comment example + manifest case.
- [x] C3.4 `zig build` and `zig build conformance` pass.

## Cycle 4: Strict Equality (P3)

- [x] C4.1 Lex `===` and `!==` in `src/lumen_lexer.zig` (3-char before 2-char).
- [x] C4.2 Accept `===`/`!==` wherever `==`/`!=` are accepted in
  `src/lumen_check.zig` and lower them identically in `src/lumen_compiler.zig`.
- [x] C4.3 Add valid `===`/`!==` example + manifest case.
- [x] C4.4 Align README/spec wording for the expanded literal/operator surface.
- [x] C4.5 `zig build` and `zig build conformance` pass.
