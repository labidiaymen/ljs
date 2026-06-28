# Implementation Plan: Class Inheritance & Members

**Branch**: `tjs-native` (milestone 018) | **Date**: 2026-06-28 |
**Spec**: [spec.md](./spec.md)

## Summary

Extend the class model (feature 010) with single inheritance and richer members.
The work touches the AST (member modifiers, `extends`, `super`, accessors), the
parser (member prefix keywords, `super(...)`/`super.m()`, `get`/`set`), the
checker (hierarchy resolution, visibility/readonly/static enforcement, accessor
typing, `implements` checks, `super` rules), and the emitter (field flattening,
inherited-method copies, `super` lowering, accessor calls, static globals).

## Technical Context

Zig 0.16.0 compiler. Classes already lower to a struct with `__init` and methods
taking `self: *Name`. This cycle keeps that shape and adds:

- **Inheritance by flattening**: `ClassDecl` gains `parent: ?[]const u8`. The
  checker resolves the ancestor chain and records, per class, the full ordered
  field list and the resolved method set (own methods override inherited ones).
  The emitter writes ancestor fields first, then own fields, then own methods,
  then inherited methods (re-emitted with `self: *Child`).
- **`super`**: `super(args)` is a dedicated `super_ctor` statement that the
  emitter inlines as the parent constructor body with parent params bound to the
  call arguments. `super.method(args)` is a `super_call` expression emitted as a
  copy of the parent method under name `__super_<Parent>_<method>` on the child.
- **Modifiers**: `TypeField` and `FunctionDecl` gain `visibility`, `is_static`,
  `is_readonly`, and an accessor kind. These are checker-enforced and (for
  statics/accessors) shape emission; they do not appear in user diagnostics as
  Zig.
- **Statics**: emitted as module-level `var __Class_field` globals and free
  functions `fn __Class_method(...)`. `ClassName.member` resolves to them.
- **Accessors**: `get x()`/`set x(v)` emit methods `__get_x` / `__set_x`;
  `obj.x` read/write routes to them when `x` is an accessor.

## Diagnostics

New codes: `E_MISSING_SUPER`, `E_PRIVATE_ACCESS`, `E_PROTECTED_ACCESS`,
`E_READONLY_ASSIGNMENT`, `E_MISSING_MEMBER`. Existing `E_TYPE_MISMATCH` /
`E_ARG_COUNT` cover static/instance confusion and `super` argument errors.

## Milestone Strategy

1. AST + parser: modifiers, `extends`, `implements`, `super`, accessors.
2. Checker: build class hierarchy info; enforce visibility/readonly/static;
   type accessors; check `super`; check `implements`.
3. Emitter: flatten fields, copy inherited/super methods, lower `super`,
   accessors, and statics.
4. Examples (valid + invalid) + manifest + build.zig wiring; verify green.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Field flattening | Keeps instance layout a single flat struct, so field access and method `self` stay trivial | Embedding a `__base` field forces qualified field access and complicates `this.x` |
</content>
