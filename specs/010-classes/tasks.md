# Tasks: Classes

- [x] T1 AST: `ClassDecl`, `MemberAssign`, `this`/`new`/`method_call` exprs.
- [x] T2 `class_type` in the type system (instances are `*Name`).
- [x] T3 Parse `class` bodies (fields, constructor, methods), `this.field`/
  `this.method()` statements, `new`, and member-expression statements.
- [x] T4 Checker: register classes (hoisted), check ctor/method bodies with
  `this`, `new`, method calls, field access, member assignment.
- [x] T5 Emit Zig struct + `__init` + methods; `this`→`self`; `new`→`__init`.
- [x] T6 Allow `this.field =` in the dynamic-write prescan; retire
  `E_UNSUPPORTED_CLASS`.
- [x] T7 Valid + invalid example + manifest; `zig build conformance`.
