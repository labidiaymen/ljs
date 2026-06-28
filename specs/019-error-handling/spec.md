# Feature Specification: Error Handling (throw / try / catch / finally)

**Feature Branch**: `tjs-native` (milestone 019) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Add structured error handling with TypeScript syntax: `throw` an
error value, and handle it with `try` / `catch (e)` / `finally`. Builds on the
shipped `defer` lowering (007): `finally` always runs on every exit from the
guarded region.

## Scope (V1)

- `throw <error>;` raises an error. The thrown value must be an error value
  (produced by `Error("message")`); throwing any other type is rejected.
- `try { ... } catch (e) { ... }` runs the catch body when the try body throws,
  binding the caught error to `e`.
- An optional `finally { ... }` block runs after the try/catch on every path:
  normal completion, a caught throw, or a throw re-raised from the catch body.
- The catch binding `e` is an error value; `e.message` reads the error text.
- `try`/`catch`/`finally` may nest. A throw is handled by the nearest enclosing
  catch; a throw inside a catch body re-propagates to the next enclosing try.
- Local variables declared in a try body share one scope across the body.

Out of scope this cycle: propagating a `throw` across a function boundary to a
caller's `catch` (an uncaught throw at top level aborts the program), `catch`
without a binding, typed/filtered catch clauses, custom error subclasses,
multiple catch clauses, and re-using the caught value as a thrown object other
than reading its message.

## Requirements

- **FR-001**: `throw e;` is accepted only when `e` has error type; otherwise the
  checker reports `E_THROW_TYPE`.
- **FR-002**: `Error("msg")` produces an error value; its single argument must be
  a `string` (else `E_TYPE_MISMATCH`) and exactly one argument is required (else
  `E_ARG_COUNT`).
- **FR-003**: When a try body throws, the matching `catch (e)` runs with `e`
  bound to the thrown error, and statements after the throw in the try body are
  skipped.
- **FR-004**: A `finally` block, when present, runs after the try/catch on every
  exit path, including when the catch body itself throws.
- **FR-005**: `try`/`catch`/`finally` nest; an inner handler that catches a throw
  does not trigger an outer handler, and a throw raised from a catch body is
  handled by the next enclosing try.
- **FR-006**: `e.message` yields the error's text as a `string`.

### Diagnostics
Uses `E_THROW_TYPE` (non-error thrown) and reuses `E_TYPE_MISMATCH` /
`E_ARG_COUNT` for malformed `Error(...)` calls.

## Success Criteria

- **SC-001**: Programs using throw/catch/finally compile and the produced native
  binary prints results in the correct order (finally last; nested handlers and
  rethrow ordered correctly).
- **SC-002**: Throwing a string, throwing a number, and constructing `Error`
  with a non-string argument each fail before native build.
- **SC-003**: `zig build conformance` passes with the feature 019 manifest.

## Notes

A `try` lowers to an optional error-message slot plus a guarded block: a `throw`
sets the slot and breaks out of the block, so the remaining try statements are
skipped; the catch body runs when the slot is set. `finally` lowers to a `defer`
over the whole try/catch region, reusing the shipped defer machinery so it runs
on normal completion and on a rethrow that unwinds to an enclosing try. The
error value is represented as its message text in V1.
