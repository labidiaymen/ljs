# Tasks — Spec 096
- [x] T1. interp_ops: instanceofOperator (§7.3.22 GetMethod @@hasInstance → ToBoolean(Call); else OrdinaryHasInstance).
- [x] T2. interp_expr: link ordinary function .prototype [[Prototype]] to %Object.prototype%.
- [x] T3. abstract_ops: remove dead/wrong instanceOf helper.
- [x] T4. Gate: build/test/lint/bench green; expressions/instanceof 57→85 (100%); language 42,152→42,187 (+35), 0 regressions.
