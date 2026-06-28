# Implementation Plan: Error Handling (019)

**Spec**: [spec.md](./spec.md) | **Date**: 2026-06-28

## Summary

Wire `throw` / `try` / `catch` / `finally` end to end on the Lumen compiler:
lexer/parser already accept the syntax and the checker already types `throw`
operands and the catch binding. This cycle hardens the Zig emission so the
guarded region lowers correctly:

- The try body emits as one shared-scope block (locals visible across
  statements) instead of one wrapper block per statement.
- `throw` inside a guarded region sets the error-message slot and breaks out of
  the try block, skipping the rest of the try body.
- `finally` lowers to a `defer` over the whole try/catch region so it runs on
  every exit, including a rethrow that unwinds to an enclosing try.
- Dead statements after an unconditional `throw` are not emitted (Zig rejects
  unreachable code), and an unused catch binding / an unmutated slot are
  discarded so the generated Zig compiles cleanly.

## Technical Context

Zig 0.16.0 backend. Touches only `src/lumen_compiler.zig` emission (the parser
and checker support already exists). The error value is its message string in
V1; `e.message` reads it.

## Approach

1. Emit the try body in a single (labeled, when it can throw) block.
2. Lower `throw` with a target to `slot = msg; break :try_label;`.
3. Emit `finally` as a leading `defer` block in an outer wrapper around the
   try/catch.
4. Choose `var` vs `const` for the slot and emit `_ = e;` / dead-code stops so
   the generated Zig has no unused-symbol or unreachable-code errors.

## Verification

- Focused examples in `examples/valid` (throw+catch+finally, nested + rethrow,
  conditional throw inside a function) compile and print the expected order.
- Invalid examples report `E_THROW_TYPE` / `E_TYPE_MISMATCH`.
- `zig build conformance` stays green including the new 019 manifest.

## Out of Scope

Cross-function throw propagation, binding-less / typed / multiple catch clauses,
custom error classes. An uncaught throw aborts at top level.
