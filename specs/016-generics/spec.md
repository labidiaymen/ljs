# Feature Specification: Generics (Monomorphized)

**Feature Branch**: `tjs-native` (milestone 016) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Add TypeScript generics to Lumen: type parameters on functions,
classes, and interfaces, plus `Array<T>` as sugar for `T[]`. Generics are
resolved by monomorphization — one concrete copy of a generic body is generated
per distinct set of concrete type arguments actually used in the program.

## Scope (V1)

- **Generic functions**: `function f<T>(x: T): T { ... }`, including multiple
  type parameters (`function pair<A, B>(a: A, b: B): ...`). Type arguments are
  inferred from the call-site argument types where possible, and may also be
  given explicitly: `f<int>(5)`.
- **Generic classes**: `class Box<T> { value: T; constructor(v: T) {...}
  get(): T {...} }`, instantiated with explicit type arguments:
  `new Box<int>(5)`. Methods and fields may reference the class type parameters.
- **Generic interfaces**: `interface Pair<A, B> { first: A; second: B }`, used
  with explicit type arguments as a value's declared type: `Pair<int, string>`.
- **`Array<T>` sugar**: the annotation `Array<T>` means exactly the same type as
  `T[]` and is interchangeable with it everywhere annotations are accepted
  (including nested forms like `Array<int>`).

A type parameter `T` stands for a single concrete element type at each
instantiation. The concrete arguments are the existing V1 types: `int`/`i32`,
`i64`, `number`/`f64`, `bool`, `string`, named record/interface types, class
types, and (for nested forms) their arrays.

Out of scope this cycle: generic type *constraints* (`<T extends U>`), default
type parameters (`<T = int>`), generic arrow-function values stored in a
variable, partial inference (some explicit + some inferred), variance, and
higher-kinded or recursive type parameters. A generic value with no usable
instantiation is simply never emitted.

## Requirements

- **FR-001**: A generic function declaration with one or more type parameters
  parses and type-checks. Each call site resolves the type parameters to
  concrete types — inferred from the argument expression types, or taken from an
  explicit `f<...>(...)` type-argument list when present.
- **FR-002**: The compiler emits one specialized, fully-typed copy of each
  generic function per distinct concrete type-argument tuple used; identical
  instantiations share a single emitted copy. Calls lower to the matching
  specialized copy.
- **FR-003**: A generic class instantiated as `new C<...>(...)` produces one
  specialized class per distinct type-argument tuple; field and method types
  follow the substituted type parameters. Member access and method calls on a
  generic instance are checked against the substituted member types.
- **FR-004**: A generic interface used as `Name<...>` denotes the record type
  obtained by substituting the type arguments into the interface fields; object
  literals and field access are checked against the substituted shape.
- **FR-005**: `Array<T>` is accepted anywhere a type annotation is accepted and
  is identical to `T[]`.
- **FR-006**: An explicit type-argument list whose length does not match the
  declared type-parameter count reports `E_TYPE_ARG_COUNT`. A call argument whose
  type contradicts an already-inferred binding for the same type parameter, or an
  explicit type argument that the supplied value does not satisfy, reports
  `E_TYPE_MISMATCH`. A call site from which a type parameter cannot be inferred
  and is not given explicitly reports `E_TYPE_INFER`.

### Diagnostics
Adds `E_TYPE_ARG_COUNT` (wrong number of type arguments) and `E_TYPE_INFER`
(a type parameter could not be inferred). Reuses `E_TYPE_MISMATCH` and
`E_ARG_COUNT`.

## Success Criteria

- **SC-001**: Identity, a multi-type-parameter function, a generic container
  class, a generic interface, and `Array<T>` sugar all compile and the produced
  native binaries print the expected results.
- **SC-002**: A type-argument-count error, a contradictory inferred binding, and
  a value that does not satisfy an explicit type argument each fail before native
  build.
- **SC-003**: `zig build conformance` passes with the feature 016 manifest and
  all previously green cases stay green.

## Notes

Monomorphization runs as a checker-driven specialization pass: while checking
the program, each generic call / instantiation records its concrete
type-argument tuple, a specialized non-generic copy of the declaration is
produced (with the type parameters substituted into every annotation), and the
call/`new` site is rewritten to target that copy. Specialized copies are then
checked and emitted by the existing concrete pipeline, so the backend needs no
generic-specific machinery. Because every instantiation is concrete, generated
code is ordinary monomorphic Zig.
