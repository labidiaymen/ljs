# Implementation Plan: Numeric Literals And Lexer Completeness

**Branch**: `tjs-native` | **Date**: 2026-06-27 | **Spec**: [spec.md](./spec.md)

## Summary

Grow the accepted TypeScript literal/operator/comment surface in four small
conformance-backed cycles, without changing the type representation or the
lowering pipeline. The single semantically significant change is making `f64`
*values* reachable from source — the type already exists end-to-end but no float
literal can currently be lexed.

## Technical Context

**Language/Version**: Zig 0.16.0 compiler implementation, generated Zig backend.

**Primary Dependencies**: Zig standard library, host `zig build-exe`.

**Testing**: `zig build`, `zig build conformance`, focused `.ts` examples.

**Constraints**: Do not touch `src/lumen_types.zig`'s type set or the emission
pipeline shape. Keep each cycle independently shippable and verified.

## Affected Modules

- `src/lumen_lexer.zig` — new token forms: float literals, non-decimal integer
  bases, digit separators, block comments, `===`/`!==`. New lexer diagnostics.
- `src/lumen_diag.zig` — add `E_INVALID_NUMBER`, `E_UNTERMINATED_COMMENT`.
- `src/lumen_ast.zig` — add a `float: f64` expression node alongside `num: i64`.
- `src/lumen_types.zig` — `inferExprType` maps the new float node to `f64`
  (no change to the `Type` set itself).
- `src/lumen_check.zig` — type the float node; reject float→int assignment;
  accept `===`/`!==` wherever `==`/`!=` are accepted.
- `src/lumen_compiler.zig` — parse the new tokens into AST nodes; emit float
  literals; treat `===`/`!==` as `==`/`!=` during lowering.
- `specs/002-numeric-literals-lexer/` — examples + conformance manifest.

## Cycle Breakdown

### Cycle 1 — Float literals (P1)

Lexer: when scanning digits, recognize a fractional part (`.` followed by a
digit) and optional exponent (`e`/`E` with optional sign), emitting a new `flt`
token carrying `f64`. AST: add `Expr.float`. Types: `inferExprType(.float) =>
f64`. Checker: float literal types as `f64`/`number`; float→int assignment is
`E_TYPE_MISMATCH`. Compiler: parse `flt` into `.float`, emit with float
formatting. Verify with valid float example + invalid float→int example.

### Cycle 2 — Integer bases and separators (P2)

Lexer: detect `0x`/`0o`/`0b` prefixes and parse in the matching base; allow `_`
separators between digits in all integer and float forms; report
`E_INVALID_NUMBER` for a prefix with no digits. Value still flows through the
existing `num: i64` path, so no AST/type change. Verify with valid base/separator
example + invalid malformed-literal example.

### Cycle 3 — Block comments (P3)

Lexer: skip `/* ... */` like the existing `//` handling, incrementing the line
counter for embedded newlines so later diagnostics stay accurate; report
`E_UNTERMINATED_COMMENT` at EOF. Verify with a multi-line block-comment example.

### Cycle 4 — Strict equality (P3)

Lexer: recognize `===`/`!==` (3-char) before `==`/`!=`. Treat them as the same
`cmp` operator tokens during checking and lowering so string content comparison
and numeric comparison are preserved. Verify with a `===`/`!==` example, then
align README/spec wording and finalize the manifest.

## Verification Per Cycle

Each cycle ends with:

1. `zig build` succeeds.
2. New valid example compiles and its native binary prints expected output.
3. New invalid example fails with the expected diagnostic before Zig emission.
4. `zig build conformance` passes the feature 002 manifest.

## Complexity Tracking

| Decision | Why | Rejected Alternative |
|----------|-----|----------------------|
| Separate `flt` token + `float` AST node | Keeps integer path (`i64`) exact; avoids float/int ambiguity in one token | Storing all numbers as `f64` would silently change integer semantics |
| `===`/`!==` lowered to `==`/`!=` | Static typing makes loose/strict equality identical here | A distinct strict-equality path would add semantics V1 does not need |
| No type-set change | Milestone is lexer-completeness, not new types | Adding new numeric types now would pull in conversion rules out of scope |
