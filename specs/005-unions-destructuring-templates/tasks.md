# Tasks: Unions, Destructuring, Template Literals

## Cycle 8: numeric literal unions (P1)
- [x] C8.1 Parse `type Name = 1 | 2 | 3;` numeric literal unions.
- [x] C8.2 Type/check values against the declared integer literals.
- [x] C8.3 Erase to integer backing type for emission.
- [x] C8.4 Valid + invalid example + manifest; `zig build conformance`.

## Cycle 9: destructuring (P2)
- [x] C9.1 Parse `let [a, b] = e;` and `let { x, y } = e;`.
- [x] C9.2 Check source type (array / named record) and bind elements/fields.
- [x] C9.3 Lower to per-binding declarations.
- [x] C9.4 Valid + invalid example + manifest; `zig build conformance`.

## Cycle 10: template literals (P3)
- [x] C10.1 Lex backtick template literals with `${...}` holes.
- [x] C10.2 Parse into a template AST node; check holes (string/numeric).
- [x] C10.3 Lower to string concatenation.
- [x] C10.4 Valid + invalid example + manifest; `zig build conformance`.
