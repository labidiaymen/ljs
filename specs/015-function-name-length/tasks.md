# M14 tasks — function name/length + class member attributes

## Cycle 1 — length + name + class enumerability (one coherent increment) — DONE
- [x] T1 `paramCount(params)` helper (interpreter) — ExpectedArgumentCount.
- [x] T2 `setFunctionLength` / `setFunctionName` (+ `symbolPropName`) helpers.
- [x] T3 func_decl + evalFunctionExpr: install length + name.
- [x] T4 NamedEvaluation: var/let/const initializer, identifier assignment, object-literal
      property value. Helper `maybeSetAnonName` (+ `isAnonymousFn`).
- [x] T5 Field-initializer NamedEvaluation (class fields, static + instance). (Param-default
      NamedEvaluation deferred — see below.)
- [x] T6 evalClass: ctor length + name; methods/accessors non-enumerable + name + length;
      `constructor` slot non-enumerable; static members on ctor; fields stay enumerable data.
      `classElementKey` made symbol-aware; `FieldInit.key_symbol` for symbol-keyed fields.
- [x] T7 Object-literal methods/accessors: name (key / "get x" / "set x"), kept enumerable.
- [x] T8 Bound functions: name "bound "+target.name, length max(0, target.length-bound).
- [x] T9 Native functions: `name` via createNative + defineMethod. (Per-native length deferred.)
- [x] T10 engine.zig unit tests (3 new test blocks).
- [x] T11 Gates ALL green (see delta below).

## Delta (HARNESS, language/ tree)
- full language/: 19924 (45.6%) -> 20932 (47.9%), +1008. TRUE regressions: 0 (runner strict
  baseline diff: "conformance: ok (no regression vs baseline)").
- language/expressions continuity: 10264 (>= 9728 floor, +536 vs baseline).
- bench: perf ok (no ljs-vs-self regression); ljs <= Node on all cases.

## Deferred (NamedEvaluation edge cases + native length)
- Per-native `length` (e.g. `Object.defineProperty.length===3`): a large per-function arity
  table; natives carry a correct `name` only for now.
- Param-default NamedEvaluation `function g(x = function(){}){}` -> `x.name === "x"`: not yet
  (the binding happens in the call path; lower-leverage). Var/let/const/assign/property/field
  NamedEvaluation all landed.
- `%Function.prototype%.name === ""`: the intrinsic's `.prototype` object carries no name
  property (minor; obscure edge).
