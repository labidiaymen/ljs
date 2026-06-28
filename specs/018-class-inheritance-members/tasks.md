# Tasks: Class Inheritance & Members

- [x] T1 AST: add `parent`/`implements` to `ClassDecl`; `visibility`,
  `is_static`, `is_readonly` to `TypeField`; `visibility`, `is_static`,
  `accessor` to `FunctionDecl`; `super_ctor` stmt and `super_call` expr.
- [x] T2 Parser: member modifier keywords (`public`/`private`/`protected`/
  `static`/`readonly`), `extends`/`implements`, `get`/`set`, `super(...)` and
  `super.m(...)`.
- [x] T3 Checker: resolve hierarchy (ordered fields + method set); enforce
  visibility, readonly, static/instance; type accessors; check `super`
  (first-statement, args, missing-super); check `implements`.
- [x] T4 Emitter: flatten ancestor fields; emit inherited + `__super_` method
  copies; inline `super(...)`; route accessor read/write; emit static globals
  and `ClassName.member` access.
- [x] T5 Examples valid + invalid; manifest mirroring 013; wire build.zig;
  `zig build conformance` stays green including new cases.
</content>
