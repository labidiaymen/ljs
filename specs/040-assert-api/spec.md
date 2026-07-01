# Spec 040: assert API

## Goal

A minimal, practical subset of Node's `assert` module: `assert.ok(cond)`,
`assert.equal(a, b)`. Wraps the language's own panic mechanism, not the
throw/catch machinery -- a static call has no access to an enclosing try's
throw target (that's threaded through statement-level emission, not
available to an arbitrary expression). A failed assertion crashes the
program, uncatchable, the same idiom as C's `assert()` or an uncaught Node
`AssertionError`. Turned out to be a real (if small) design decision, not
the "near-free" wrapper job it looked like at first -- worth a full spec
rather than folding silently into the Math completion pass.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `assert.ok(cond)` | `bool -> void` | panics with a fixed message if `cond` is false |
| `assert.equal(a, b)` | `(T, T) -> void` | panics with the two mismatched values in the message if not equal; both args must be the same type |

## Design notes

- **Panic, not throw**: reusing the throw/catch machinery would need a
  static call deep in an expression tree to somehow reach the enclosing
  statement's throw target, which the checker/emitter don't thread through
  expression checking at all today. A direct `@panic`/`std.debug.panic`
  sidesteps this entirely: verified the failure path actually halts
  execution (a statement after a failed `assert.ok`/`assert.equal` never
  runs) and produces a clean, formatted "runtime error: ... at file:line:col"
  message via the compiler's existing panic-diagnostic wrapping, the same
  one every other runtime panic in a Lumen program already gets -- not
  something built for this feature specifically.
- **String comparison**: `assert.equal` routes to a dedicated
  `__assertStrEqual` when both arguments are `string`, comparing bytes via
  `std.mem.eql` rather than slice identity -- the exact same routing trick
  `expect(...).toBe(...)` already uses for its own `__expectStrEqual`.
- **Why not reuse `expect`/`toBe` directly**: that mechanism lowers to
  `std.testing.expectEqual`/`expectEqualStrings` via `try`, which relies on
  the `zig test` runner's error-propagation contract (used inside `test()`
  blocks specifically) -- not something usable from a plain `main()`-based
  program, so `assert` needed its own, simpler panic-based mechanism
  instead of sharing code with the test runner.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `assert.deepEqual`/`deepStrictEqual` | needs recursive structural comparison across records/arrays; `equal`'s flat scalar/string comparison covers the common case for v1 |
| `assert.throws`/`doesNotThrow` | needs a way to catch a panic and inspect it, which is a bigger feature than this pass (panics are uncatchable by design here) |
| A custom message argument (`assert.ok(cond, "custom message")`) | straightforward to add later; the fixed/auto-generated messages cover the common case |
