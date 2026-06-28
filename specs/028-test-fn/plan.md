# Implementation Plan: `test(...)` function form & `expect().toBe()`

## Approach

Both test surfaces lower to the existing 008 `test_decl` AST node, which already
emits a Zig `test "name" { ... }` block and runs under `lumen test`. The function
form is therefore purely a parser-recognition change — no new AST, checker, or
emitter wiring for the test body itself.

The `expect(actual).toBe(expected)` matcher is recognized at parse time and
lowered to a single `call` node so it never flows through the generic
`method_call` machinery (which is type-driven and meant for real object methods).
The matcher node lowers to a `std.testing` equality helper.

## Pieces

1. **Parser** (`src/lumen_compiler.zig`, `parseStmt`)
   - In the existing `test` branch, after the `test "name" { ... }` lookahead,
     add a sibling branch: when `(` follows `test`, parse
     `test("name", () => { BODY });` — name string, comma, `()` `=>`, block body,
     `)`, `;` — and return the same `test_decl`. Recognition is by lookahead, so
     `test` stays usable as an identifier.
   - Add an `expect` statement branch (guarded by `peekIsOpenParen`):
     - `expect(actual).toBe(expected);` / `.toEqual(...)` → a `call` node named
       `__expectToBe` / `__expectToEqual` with args `[actual, expected]`.
     - `expect(cond);` → the existing `call` named `expect` with one arg.
     - An unknown matcher sets `last_err = "E_UNKNOWN_MATCHER"` and fails parse.

2. **Checker** (`src/lumen_check.zig`, `exprType` `.call` arm)
   - For `__expectToBe` / `__expectToEqual`: require `test_depth > 0`, exactly two
     args, and matching operand types (else `E_TYPE_MISMATCH`); result `.void`.
   - When both operands are `.string`, rewrite `call.name` to `__expectStrEqual`
     so strings compare by bytes, not slice identity.
   - The boolean `expect` arm is unchanged from 008.

3. **Emitter** (`src/lumen_compiler.zig`, `emitExpr` `.call` arm)
   - `__expectToBe` / `__expectToEqual` → `try std.testing.expectEqual(expected, actual)`
     (Zig's `expectEqual` takes `(expected, actual)`).
   - `__expectStrEqual` → `try std.testing.expectEqualStrings(expected, actual)`.
   - The boolean `expect` → `try std.testing.expect(cond)` (unchanged).

## Out of scope

- No changes to `lumen test` / `lumen compile` driving or the conformance runner;
  both forms reuse the 008 `test-run` and `diagnostics` phases.
- No new matchers, async callbacks, hooks, or `describe` grouping (see spec
  "Deferred").
