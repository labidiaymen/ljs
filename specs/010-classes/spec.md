# Feature Specification: Classes

**Feature Branch**: `tjs-native` (milestone 010) | **Created**: 2026-06-27 |
**Status**: Draft

**Input**: Add classes — fields, a constructor, `this`, and methods. Instances
are heap-allocated and lower to a Zig struct with an `__init` constructor and
methods taking `self: *Name`.

## Scope (V1)

Fields, a single `constructor`, instance methods, `this.field` read/write inside
methods, `this.method(...)`, `new Name(args)`, and `obj.field` / `obj.method()`
from outside. Out of scope for this cycle: inheritance (`extends`/`super`),
visibility modifiers, static members, getters/setters, and external field writes
(`obj.field = ...` from outside a method).

## Requirements

- **FR-001**: `class Name { field: T; constructor(p: T) { ... } method(p: T): R
  { ... } }` declares a class. Class names are usable as types.
- **FR-002**: `new Name(args)` constructs a heap instance; argument count and
  types are checked against the constructor (or must be empty if there is none).
- **FR-003**: `this` inside a method/constructor has the class type; `this.field`
  reads a field and `this.field = value` (and compound `+=` etc.) writes it.
- **FR-004**: `obj.field` reads a field; `obj.method(args)` calls a method with
  checked argument count/types, yielding the method's return type.
- **FR-005**: A non-class used with `new`, an unknown field/method, or a
  type-mismatched constructor/method argument reports `E_TYPE_MISMATCH` (or
  `E_ARG_COUNT`).

## Success Criteria

- **SC-001**: A class with a constructor, fields, and methods compiles, and a
  constructed instance's methods produce expected output.
- **SC-002**: A constructor argument of the wrong type fails with
  `E_TYPE_MISMATCH`.
- **SC-003**: `zig build conformance` passes with the feature 010 manifest.

## Notes

Classes lower to `const Name = struct { fields; fn __init(...) *Name { ... }
fn method(self: *Name, ...) ... };`. Instances are allocated with the page
allocator (allocate-and-leak, consistent with the V1 memory model); there is no
destructor. `E_UNSUPPORTED_CLASS` is retired.
