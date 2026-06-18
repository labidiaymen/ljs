# Tasks — M79

- [x] T001 Histogram failing clusters across the 8 generator/async-generator/yield/for-await/await
      dirs; isolate the `arguments`-in-params and generator-`prototype` clusters as the
      highest-leverage in-subsystem wins.
- [x] T002 `instantiateGeneratorParams`: create + bind `arguments` before the param loop; add
      `paramsBindName` for the suppression check; remove the old post-loop creation.
- [x] T003 Verify with repros: param-default `arguments`, body `function arguments(){}`, and a
      parameter named `arguments` (suppression).
- [x] T004 Add `finalizeFunctionPrototype`; wire into the func_decl arm and `evalFunctionExpr`.
- [x] T005 `createGenerator` / `createAsyncGenerator`: OrdinaryCreateFromConstructor instance proto.
- [x] T006 Verify: `Object.getPrototypeOf(g()) === g.prototype`, `.prototype` descriptor
      `{w:true,e:false,c:false}`, `Object.getPrototypeOf(g.prototype) === %GeneratorPrototype%`,
      generator still resumes via `.next`.
- [x] T007 Improve `$DONE` async-fail diagnostic (name: message extraction).
- [x] T008 Gate: `zig build` / `zig build test` / `zig build lint` green; full `language/` run vs
      baseline = 0 regressions; `zig build bench` ok.
