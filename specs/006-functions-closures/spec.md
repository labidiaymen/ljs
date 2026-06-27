# Feature Specification: First-Class Functions

**Feature Branch**: `tjs-native` (milestone 006) | **Created**: 2026-06-27 |
**Status**: In progress (cycles 1-2 landed; 3-4 pending)

**Input**: Make functions first-class. Keystone for callbacks and async.

## Cycles

1. **Function-typed values & params** (landed): `(x: int) => int` type
   annotations; pass named functions as values; call through a function-typed
   binding. Lowers to Zig function pointers (`*const fn(...) R`).
2. **Arrow functions** (landed): `(x: int) => expr` — typed params, expression
   body, no capture; lowered inline to an anonymous Zig function pointer.
3. **Closures** (pending): capturing arrows via a heap environment + fat pointer.
4. **Array higher-order methods** (pending): `map`/`filter`/`reduce`/`forEach`.

V1 limits: arrow params require type annotations; arrow bodies are expressions
(no block body); no capture of enclosing locals yet (referencing one is an
"undefined variable" error until cycle 3).

## Requirements

- **FR-001**: A function type `(name: T, ...) => R` is a valid annotation for
  bindings, parameters, and return types.
- **FR-002**: A top-level function name used as a value has its function type and
  may be passed as an argument or assigned to a function-typed binding.
- **FR-003**: Calling a function-typed binding checks argument count and types
  against the signature and yields the return type.
- **FR-004**: An arrow `(x: T) => expr` has type `(T) => typeof expr` (or the
  annotated return type) and type-checks its body with only its parameters in
  scope.
- **FR-005**: Passing an argument whose function type does not match the expected
  parameter type reports `E_TYPE_MISMATCH`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria
- **SC-001**: Passing named functions and arrows to a higher-order function
  compiles and prints expected results.
- **SC-002**: A function-type argument mismatch fails before Zig emission.
- **SC-003**: `zig build conformance` passes with the feature 006 manifest.
