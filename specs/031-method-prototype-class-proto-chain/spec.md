# 031 — MethodDefinition has no `.prototype`; base-class `C.prototype.[[Prototype]]` = %Object.prototype% (§10.2.5 / §15.7.14)

## Problem
Two systematic, related defects in how ljs builds function and class objects made a large slice of
the `statements/class` and `expressions/class` buckets fail (and tainted any object-method test that
inspects descriptors):

1. **Every non-arrow function got an own `.prototype`.** `Object.createFunction` added a `prototype`
   data property to *all* non-arrow functions. Per ECMA-262 only a *constructor* function gets one
   (MakeConstructor, §10.2.5). A §15.4 **MethodDefinition** function — a class/object method,
   getter, setter, or `async` (non-generator) method — is created with `kind: method` and is NOT a
   constructor: it has NO own `prototype`. An §15.8 **AsyncFunction** (declaration/expression) is
   likewise not a constructor. So `'prototype' in C.prototype.m`, `'prototype' in
   Object.getOwnPropertyDescriptor(C.prototype, 'x').get`, `'prototype' in asyncFn`, etc. all
   wrongly returned `true`. (A *generator* / *async-generator* method IS a GeneratorFunction and
   DOES keep its generator `.prototype` — the one exception.)

2. **A base class's `C.prototype.[[Prototype]]` was `null`.** The class evaluator only set
   `proto.[[Prototype]]` for *derived* classes (to `Super.prototype`). For a base class (no
   `extends`) it left the freshly-created prototype object's `[[Prototype]]` at `null` (whatever
   `createFunction` produced), so `Object.getPrototypeOf(C.prototype) === Object.prototype` was
   `false` and `C.prototype.hasOwnProperty`/`toString`/… were missing. Per §15.7.14 step 6.a a base
   class has `protoParent = %Object.prototype%`.

```js
class C { m(){} get x(){return 1} }
'prototype' in C.prototype.m;                                          // was true  → must be false
'prototype' in Object.getOwnPropertyDescriptor(C.prototype,'x').get;   // was true  → must be false
Object.getPrototypeOf(C.prototype) === Object.prototype;               // was false → must be true
async function af(){}; 'prototype' in af;                              // was true  → must be false
```

## Spec clauses
- §10.2.4 MakeConstructor / §10.2.5 MakeMethod — only a constructor function has a `.prototype`; a
  method does not.
- §15.4 MethodDefinitionEvaluation (`kind: method`), §15.3 ArrowFunction, §15.8 AsyncFunction — none
  are MakeConstructor targets.
- §15.5 / §15.6 Generator / AsyncGenerator — generator (sync/async) methods and functions DO get a
  `.prototype` (the generator-instance prototype).
- §15.7.14 ClassDefinitionEvaluation step 6 — `protoParent` is %Object.prototype% for a base class,
  `Super.prototype` for a derived class, `null` for `extends null`.

## Solution
- Add `is_method` to `ast.Function` and to `object.FunctionData`; the parser sets it on every
  MethodDefinition node (class methods/accessors, object-literal methods/accessors). It threads
  through `evalFunctionExpr` into the function object.
- `Object.createFunction` now computes `wants_prototype = is_generator OR (!is_arrow AND !is_async
  AND !is_method)` — a generator (sync or async) always gets one; otherwise only a plain
  (non-arrow, non-async, non-method) function does. `setConstructorBackref` skips methods too.
- In `ClassDefinitionEvaluation`, the base-class branch sets `proto.[[Prototype]] =
  %Object.prototype%` (the derived branch already linked to `Super.prototype`).

## Outcome
Full `language/`: passed 36455 → 36555 (**+100**, 83.5% → 83.7%), **0 regressions** vs baseline.
Newly passing: 62 `statements/class`, 36 `expressions/class`, 2 `expressions/object`. The
per-function `prototype` decision is a pure construction-time branch (no hot-loop cost); the
class-proto relink is one assignment at class-definition time.
