# Spec 039: Math completion

## Goal

Close the `Math`/`Array` "more" row already sitting in the Planned table:
`floor`/`ceil`/`round`/`trunc`/`pow`/`log`/`sin`/`cos`/`Math.PI`. Not a new
namespace or pattern -- just more functions in an already-shipped,
already-tested one, mirroring `Math.abs`/`sqrt`'s exact wrapper shape. Zero
new design, zero portability risk (pure computation, works identically on
native and wasm).

## API

| Function | Type | Notes |
| --- | --- | --- |
| `Math.floor(n)` / `ceil(n)` / `round(n)` / `trunc(n)` | `number -> int` | the value is inherently a whole number, same reasoning as `Math.sign` returning `int` |
| `Math.pow(base, exp)` | `(number, number) -> number` | both args must be the same type, same rule as `Math.max`/`min`; the result can be fractional even from integer inputs, so it always returns `number`, like `sqrt` |
| `Math.log(n)` / `sin(n)` / `cos(n)` | `number -> number` | natural log; always `number`, like `sqrt` |
| `Math.PI()` | `() -> number` | a zero-arg function, not a property -- the same deviation as `path.sep()`/`process.platform()` (no static-namespace constant-property mechanism yet) |

## Design notes

- **A real bug found and fixed along the way, in code that predates this
  milestone**: a "whole" float literal like `4.0` lowers to the bare
  numeral `4` in the generated code (no decimal point). That's fine
  wherever the target already has an explicit `number` type context (Zig
  coerces a bare integer literal to a float parameter automatically), but
  the language's own `floor`/`ceil`/`round`/`trunc`/`log`/`sin`/`cos`/`sqrt`/
  `abs` primitives don't perform that coercion on their own for a literal
  that looks like a whole number. Every one of those (including the
  pre-existing `sqrt`/`abs`, not just the ones added this pass) now forces
  the float type explicitly rather than assuming an already-`number`-typed
  argument is safe to pass through as-is. Confirmed by testing both a
  fractional literal (already worked) and a whole-number literal
  (previously failed to compile) for each affected function.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `a.push`/`pop`/`sort` (the other half of the original Planned-table row) | growable arrays, a real language-level gap unlike the rest of this pass, which was pure wrapper work |
