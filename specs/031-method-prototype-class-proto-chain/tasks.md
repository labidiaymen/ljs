# 031 — Tasks

- [x] T1 — Add `is_method` to `ast.Function` (§15.4 MethodDefinition marker).
- [x] T2 — Set `is_method = true` at the 5 parser MethodDefinition sites: class method (§15.7),
  class accessor (get/set), object-literal method, object-literal accessor (get/set).
- [x] T3 — Add `is_method` to `object.FunctionData`; thread it through `evalFunctionExpr`.
- [x] T4 — `Object.createFunction`: only add `.prototype` when
  `is_generator OR (!is_arrow AND !is_async AND !is_method)` (§10.2.4/§10.2.5).
- [x] T5 — `setConstructorBackref`: skip method functions (no `.prototype` to attach `constructor`).
- [x] T6 — `ClassDefinitionEvaluation`: base class sets `proto.[[Prototype]] = %Object.prototype%`
  (§15.7.14 step 6.a); derived/`extends null` branches unchanged.
- [x] T7 — `src/engine.zig` tests: method/getter/setter/async/arrow have no `.prototype`; generator
  & async-generator methods, plain/generator functions, class ctor keep it; base/derived class
  prototype chain; `new` still works.
- [x] T8 — Gates: `zig build`, `zig build test`, `zig build lint` (0/0), full `language/`
  conformance (+100, 0 regressions), `zig build bench` (perf ok). Update baseline.
