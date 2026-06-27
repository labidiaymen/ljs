# Implementation Plan: Unions, Destructuring, Template Literals

**Branch**: `tjs-native` | **Spec**: [spec.md](./spec.md)

## Summary

Final roadmap milestone, three scoped V1 cycles. Numeric literal unions mirror
the existing string-literal-union machinery; destructuring lowers to per-binding
declarations; template literals lower to `std.fmt.allocPrint` concatenation.

## Affected Modules

- `src/lumen_types.zig` — `int_literal_union` variant.
- `src/lumen_ast.zig` — `DestructureDecl` stmt, `template`/`TemplatePart` exprs,
  `int_literals` on `TypeDecl`.
- `src/lumen_lexer.zig` — backtick template token.
- `src/lumen_check.zig` — numeric union typing, destructuring binding,
  template hole typing.
- `src/lumen_compiler.zig` — parse `type = N | N`, `[a,b]`/`{x,y}` patterns, and
  backtick templates; emit union erasure, per-binding consts, and allocPrint.
- `build.zig` — wire the 005 manifest.

## Cycle Breakdown

- **C8 numeric literal unions** — `type Code = 1 | 2 | 3` checked against the
  declared literals (assignment, switch, equality), erased to `i32`.
- **C9 destructuring** — `let [a,b] = arr` / `let {x,y} = rec` lowered to a temp
  plus one `const` per binding (no wrapping block, so bindings stay in scope).
- **C10 template literals** — backtick literals split into text/hole parts;
  string/numeric/bool holes; lowered to `std.fmt.allocPrint`.

## Verification Per Cycle
`zig build`, valid + invalid example, `zig build conformance`.

## Notes / Limitations
General tagged/record unions, nested/rest destructuring, pattern defaults, and
tagged template functions remain future work.
