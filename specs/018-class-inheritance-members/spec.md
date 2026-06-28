# Feature Specification: Class Inheritance & Members

**Feature Branch**: `tjs-native` (milestone 018) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Build on feature 010 (classes) to add inheritance and richer members:
`extends` with `super(...)` and `super.method()`, member visibility
(`public` / `private` / `protected`, enforced), `static` fields and methods,
`readonly` fields, getters/setters, and optional `implements` of an interface.

## Scope (V1)

- `class Child extends Parent { ... }` — single inheritance. The child inherits
  the parent's fields and methods; it may add fields/methods and override
  methods.
- `super(args)` as the first statement of a child constructor runs the parent
  constructor logic. `super.method(args)` calls the parent's implementation of
  an (overridden) method.
- Visibility modifiers `public` (default), `private`, `protected` on fields and
  methods, enforced by the checker. `private` is accessible only inside the
  declaring class; `protected` inside the declaring class and its subclasses;
  `public` everywhere.
- `static` fields and methods belong to the class, accessed as `ClassName.member`
  rather than on an instance.
- `readonly` instance fields may be assigned in the constructor but never
  reassigned afterward (inside methods or from outside).
- `get name(): T { ... }` / `set name(v: T) { ... }` accessors, read as
  `obj.name` and written as `obj.name = value`.
- `class C implements I { ... }` checks that `C` provides every member declared
  by interface `I`.

Out of scope: multiple inheritance, abstract classes, `protected`/`private`
constructors, static blocks, parameter properties, and decorators.

## Requirements

- **FR-001**: `class C extends B` makes `C` inherit `B`'s fields and methods.
  `new C(...)` checks arguments against `C`'s constructor (which must call
  `super(...)` if `B` has a constructor with parameters).
- **FR-002**: `super(args)` is allowed only inside a child constructor and only
  as the first statement; argument count/types are checked against the parent
  constructor. A child whose parent has a parameterized constructor and that
  omits `super(...)` reports `E_MISSING_SUPER`.
- **FR-003**: `super.method(args)` calls the parent implementation; the name must
  be a method of an ancestor and arguments are checked.
- **FR-004**: Accessing a `private` member outside its declaring class reports
  `E_PRIVATE_ACCESS`; accessing a `protected` member outside the class hierarchy
  reports `E_PROTECTED_ACCESS`.
- **FR-005**: Writing a `readonly` field outside the constructor reports
  `E_READONLY_ASSIGNMENT`.
- **FR-006**: `static` members are accessed as `ClassName.member`; accessing a
  static member on an instance, or an instance member statically, reports
  `E_TYPE_MISMATCH`.
- **FR-007**: `get`/`set` accessors expose a property `obj.name` backed by method
  bodies; reading uses the getter, writing uses the setter.
- **FR-008**: `class C implements I` reports `E_MISSING_MEMBER` if `C` lacks a
  field or method required by interface `I`.

## Success Criteria

- **SC-001**: A subclass that overrides a method, calls `super(...)` and
  `super.method()`, uses a static counter, and a getter compiles and prints the
  expected output.
- **SC-002**: Each invalid case (private access, readonly write, missing super)
  fails with its specific diagnostic.
- **SC-003**: `zig build conformance` passes with the feature 018 manifest and
  all pre-existing manifests stay green.

## Notes

Inheritance lowers by flattening: a child struct contains its ancestors' fields
followed by its own, and re-emits inherited (non-overridden) methods bound to the
child. `super(...)` inlines the parent constructor body; `super.method()` is
emitted as a parent-method copy under an internal name. Visibility, `readonly`,
and `static`/instance separation are checker-only rules and do not change the
runtime layout. Generated backend details remain invisible to the language.
</content>
</invoke>
