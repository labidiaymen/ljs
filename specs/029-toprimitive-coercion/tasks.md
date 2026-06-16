# 029 — Tasks

- [x] T1 Add `toPrimitive` to the well-known symbol set (`src/builtins.zig` `well_known`).
- [x] T2 Add `wellKnownToPrimitive()` resolver on the interpreter (mirror `wellKnownIterator`).
- [x] T3 Implement `toPrimitive(self, v, hint)` (§7.1.1) + `ordinaryToPrimitive` (§7.1.1.1) in
      `src/interpreter.zig`. Honour `@@toPrimitive`; else valueOf/toString by hint; TypeError if
      no primitive results / `@@toPrimitive` returns object.
- [x] T4 Add interpreter coercion wrappers `toNumberV`/`toStringCoerceV` that ToPrimitive an object
      first, then delegate to the pure `abstract_ops` helpers; and `relationalV`/`looseEqualsV`
      that ToPrimitive object operands.
- [x] T5 Route `evalBinary` through the wrappers: `+` (default hint, both sides), arithmetic /
      bitwise / shift (`numericBinary`, number), relational (`relationalV`, number hint, left
      first), `==`/`!=` (`looseEqualsV`, object→default).
- [x] T6 Route unary `-`/`+`/`~` and prefix/postfix `++`/`--` (incl. member/index/private) numeric
      reads through `toNumberV`; template substitution through `toStringCoerceV`.
- [x] T7 Route `Number()`/`String()` ctors through the wrappers.
- [x] T8 Wrapper boxing: add `Object.primitive` [[NumberData]]/[[StringData]]/[[BooleanData]] slot,
      set on `new Number/String/Boolean`, read by Number/Boolean/String prototype valueOf/toString.
      Fixed `new Object()` proto-link to %Object.prototype%; added `Object.prototype.valueOf`.
- [x] T9 `src/engine.zig` tests for the acceptance cases (ToPrimitive + wrapper unboxing).
- [x] T10 Gates: build/test/lint green; full `language/` 34177→34895 (78.3%→79.9%), 0 regressions;
      bench perf: ok. Baseline updated.
