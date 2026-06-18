# Plan — M79

## Files / functions touched (all in `src/interpreter.zig`, the generator subsystem)
- `instantiateGeneratorParams` — create + bind the `arguments` exotic BEFORE the parameter loop;
  suppress it only when a parameter (or rest identifier) is named `arguments`. Remove the old
  post-loop creation.
- new `paramsBindName(fd, name)` — does FormalParameters' BoundNames contain `name` (identifier /
  rest-identifier forms; the destructuring-binds-`arguments` edge is not in the corpus).
- new `finalizeFunctionPrototype(obj)` — re-`defineData` the function's own `prototype` with the
  correct §10.2.4 descriptor; for a generator/async-generator function, mark it non-configurable
  and link `prototype.[[Prototype]]` to `%GeneratorPrototype%` / `%AsyncGeneratorPrototype%`. Called
  from both user-function creation paths (func_decl arm + `evalFunctionExpr`) after
  `setConstructorBackref`.
- `createGenerator` / `createAsyncGenerator` — OrdinaryCreateFromConstructor: the instance's
  `[[Prototype]]` is `Get(func,"prototype")` when an object, else the realm intrinsic.
- `testDone` ($DONE native) — extract a thrown error's `name: message` for a readable async-fail
  diagnostic (pure diagnostic improvement, no behavior change to test classification).

## Design calls
- `arguments` is created before params in the GENERATOR path only (the ordinary-function
  `callFunction` path has the same latent ordering issue but is owned by the general call region and
  out of this subsystem's scope; noted for the integration owner).
- Suppression keyed on a parameter literally named `arguments` — matches §10.2.11's
  `parameterNames` check for every corpus case (param-expression functions still get the object,
  which is exactly what `arguments-with-arguments-*` expect: length 0 for a 0-arg call).

## Constitution Check
- Correctness-leads: all changes are spec-clause-anchored; verified by minimal standalone repros
  and the Test262 generator/async-generator dirs.
- Perf no-regression: `finalizeFunctionPrototype` runs once per function-object creation (outside
  hot loops); the generator-instance proto lookup is one `Get` at generator construction. `zig build
  bench` must show no ljs-vs-self regression (absolute pre-commit gate).
