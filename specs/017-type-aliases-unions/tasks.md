# Tasks: Type Aliases, Discriminated Unions, and `as`

## Slice 1: aliases (P1)
- [x] T1.1 AST: add `alias` annotation field to `TypeDecl`.
- [x] T1.2 Parser: `type X = <annotation>;` single-annotation body.
- [x] T1.3 Checker: alias registry + transitive resolution in `typeFromAnnotation`.
- [x] T1.4 Scratch program compiles + runs.

## Slice 2: discriminated unions (P2)
- [x] T2.1 Type: add `union_type`; types.zig support (same/zigName/mangle).
- [x] T2.2 Parser: `type U = A | B;` variant-name body.
- [x] T2.3 Checker: UnionInfo registry, discriminant validation, assignability,
  field-access gating.
- [x] T2.4 Narrowing in switch + if; `.var_ref` returns the narrowed variant.
- [x] T2.5 Emit flat struct with defaulted fields.
- [x] T2.6 Scratch program compiles + runs.

## Slice 3: `as` assertions (P3)
- [x] T3.1 AST: `cast` node. Parser: postfix `expr as T`.
- [x] T3.2 Checker: safe-subset validation; result type = target.
- [x] T3.3 Emitter: erase to inner expression.
- [x] T3.4 Scratch program compiles + runs.

## Slice 4: conformance (P4)
- [x] T4.1 Valid examples (alias use, discriminated-union switch).
- [x] T4.2 Invalid examples: variant-only field on un-narrowed union, bad
  narrowing, illegal cast.
- [x] T4.3 Manifest + wire into `build.zig`; `zig build conformance` green.
</content>
