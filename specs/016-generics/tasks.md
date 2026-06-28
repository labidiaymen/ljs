# Tasks: Generics (Monomorphized)

## Slice 1: generic functions (P1)
- [x] T1.1 Type: add annotation round-trip (`types.toAnnotation`) for inferred args.
- [x] T1.2 AST: `type_params` on decls; `type_args` on `call`/`new_expr`.
- [x] T1.3 Parser: type-parameter lists on `function`; explicit `f<...>(...)`.
- [x] T1.4 Checker: collect generic funcs; infer type args; substitute; build,
  check, cache specialized copies; rewrite call sites.
- [x] T1.5 Emitter: skip generic originals; specialized copies emit normally;
  discard unused params/locals so monomorphic copies compile.
- [x] T1.6 Scratch program (identity + multi-param + explicit) compiles + runs.

## Slice 2: Array<T> sugar (P2)
- [x] T2.1 Parser: `Array<X>` annotation -> `X[]`.
- [x] T2.2 Scratch program compiles + runs.

## Slice 3: generic classes + interfaces (P3)
- [x] T3.1 Parser: `class C<T>`, `interface P<A,B>`, `Name<...>` annotation,
  `new C<...>(...)`.
- [x] T3.2 Checker: specialize classes on `new C<...>`; specialize interface
  record types on `Name<...>`.
- [x] T3.3 Scratch program compiles + runs.

## Slice 4: conformance (P4)
- [x] T4.1 Valid examples: identity/multi-param/explicit, Array<T>, generic
  class, generic interface.
- [x] T4.2 Invalid examples: type-arg count, contradictory inference, explicit
  type-arg value mismatch, uninferable type parameter.
- [x] T4.3 Manifest + wire into `build.zig`; `zig build conformance` green.
