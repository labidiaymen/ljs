# M79 — Generator `arguments`-in-params + generator-instance prototype semantics

Status: Done (measured: +20 `language/{statements,expressions}/generators`, +2
`language/expressions/async-generator`; 0 regressions over `language/`).

## Goal
Fix two shared-root-cause clusters in the generator / async-generator drivers (all within the
generator-owning regions of `src/interpreter.zig`):

1. **`arguments` unavailable in a generator's parameter scope** — a generator whose parameter
   default (or a body `function arguments(){}`) references `arguments` threw a `ReferenceError`,
   because `instantiateGeneratorParams` created the `arguments` exotic AFTER the parameter loop
   instead of before it (§10.2.11 FunctionDeclarationInstantiation binds `arguments` ahead of
   parameter initialization).
2. **Generator-instance `[[Prototype]]` and the function's `.prototype` metadata were wrong** —
   `Object.getPrototypeOf(g()) !== g.prototype`, and `g.prototype` was an enumerable/configurable
   property with a null `[[Prototype]]`. §27.5.1.1 OrdinaryCreateFromConstructor links a new
   generator to `Get(g,"prototype")`; §27.3/§27.4 make a generator function's `.prototype` a
   `{writable:true, enumerable:false, configurable:false}` property whose `[[Prototype]]` is
   `%GeneratorPrototype%` / `%AsyncGeneratorPrototype%`.

## Failing clusters addressed (Test262, histogrammed by reason)
- `generators/{arguments-with-arguments-fn,arguments-with-arguments-lex,params-dflt-ref-arguments}`
  (statements + expressions) — `ReferenceError: arguments` / wrong default value. 6 files.
- `generators/{prototype-value,prototype-property-descriptor}` (statements + expressions) and the
  async-generator equivalents — `Object.getPrototypeOf(g()) === g.prototype` and the `.prototype`
  descriptor. 4+ files.

## Governing clauses
- §10.2.11 FunctionDeclarationInstantiation (arguments object created/bound before parameter init;
  suppressed only when a parameter is named `arguments`).
- §27.5.1.1 / §27.6.1.1 OrdinaryCreateFromConstructor (generator / async-generator instance proto).
- §10.2.4 MakeConstructor + §27.3.3 / §27.4 (the `.prototype` own-property descriptor and link).

## Out of scope (left for follow-ups / other owners)
- `%GeneratorFunction.prototype%` (%Generator%) intrinsic chain — needed by `default-proto` and
  `prototype-relation-to-function`; touches `builtins.zig` realm setup (not this subsystem).
- The `yield*` async-from-sync execution-order / tick-accuracy cluster (`yield-star-*`) — deep
  AsyncFromSyncIterator continuation work, deferred.
- Array/object destructuring iterator-protocol + non-enumerable-rest clusters
  (`dstr/*-array-prototype`, `dstr/*obj-ptrn-rest-skip-non-enumerable`) — these live in the shared
  `bindPattern` destructuring path (spec 067 area), not the generator drivers.

## Acceptance (Given/When/Then)
- Given `function*(x = arguments[2], …)` called with `undefined` placeholders, When the generator is
  created, Then the defaults read the live `arguments` exotic (no ReferenceError).
- Given `function* g(x = args = arguments){ function arguments(){} } ; g()`, Then `typeof args ===
  'object'` and `args.length === 0`.
- Given `function* g(){}`, Then `Object.getPrototypeOf(g()) === g.prototype`, the `g.prototype`
  descriptor is `{writable:true, enumerable:false, configurable:false}`, and
  `Object.getPrototypeOf(g.prototype) === %GeneratorPrototype%`.

## Success criteria
- +20 passing in `language/{statements,expressions}/generators`; +2 in
  `language/expressions/async-generator`; 0 regressions across `language/` vs baseline; bench ok.
