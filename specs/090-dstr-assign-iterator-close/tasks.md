# Tasks — Spec 090 Destructuring-assignment IteratorClose

- [x] T1. `interpreter.zig`: `AssignRef` / `AssignRefOrAbrupt` named types.
- [x] T2. `interp_destr.zig`: array-pattern `assignPattern` loop evaluates each element/rest target
      reference BEFORE stepping the iterator (§13.15.5 order); `evalElementRef`, `putElementRef`,
      `elementDefault` (incl. `assign_pattern`), `destrCloseAbrupt` (§7.4.11 completion precedence).
- [x] T3. `parse_expr.zig`: `validateAssignmentTarget` accepts an `assign_pattern` element.
- [x] T4. Gate: build/test/lint/bench green; full `language/` sweep 41,412 → 41,500 (+88), 93.3%,
      0 regressions vs baseline, 0 panics. expressions/assignment/dstr 640/640, for-of +42.
