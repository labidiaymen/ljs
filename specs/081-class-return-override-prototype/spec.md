# 081 — Class runtime semantics: derived-ctor return override + static `prototype` guard

Status: Done — statements/class +32 (8067→8099), expressions/class +2 (7596→7598); full
`language/` tree 0 regressions vs baseline (39801/44475 = 89.5%).

## Summary
Two independent, high-leverage CLASS runtime-semantics fixes found by histogramming
`language/statements/class` + `language/expressions/class` failures:

1. **Derived-constructor return override (§10.2.2 [[Construct]] step 13).** A derived
   constructor that returns a non-`undefined`, non-Object value (e.g. `return null;`,
   `return 5;`) must throw a **TypeError**. ljs previously fell through to the freshly
   created `this` and silently swallowed the primitive return.
2. **Constructor `prototype` own-property attributes + static `prototype` element guard
   (§15.7.14 / §10.2.4 MakeConstructor).** A class constructor's `prototype` own property
   must be `{ writable:false, enumerable:false, configurable:false }`. A **static** class
   element keyed `"prototype"` (literal or a computed key evaluating to the string
   `"prototype"`) must throw a **TypeError** (DefinePropertyOrThrow on the non-configurable
   slot). ljs previously left `prototype` writable and let static `prototype` elements
   clobber it.

## Governing clauses
- ECMA-262 §10.2.2 OrdinaryCallEvaluateBody / [[Construct]] step 13 (return override).
- ECMA-262 §10.2.4 MakeConstructor (the `prototype` data property attributes).
- ECMA-262 §15.7.14 ClassDefinitionEvaluation (static element DefinePropertyOrThrow).

## User scenarios (Given/When/Then)
- **Given** `class B{} class D extends B{ constructor(){ super(); return null; } }`,
  **When** `new D()`, **Then** a TypeError is thrown. (Same for `return 5`, `return "x"`,
  `return true`, `return Symbol()`.)
- **Given** a base class `class B{ constructor(){ return 5; } }`, **When** `new B()`,
  **Then** the result is the instance (base classes ignore a primitive return) — no regression.
- **Given** `class C{}`, **When** `Object.getOwnPropertyDescriptor(C,'prototype')`, **Then**
  `{writable:false, enumerable:false, configurable:false}`.
- **Given** `class C{ static get ['prototype'](){} }` (also `static set`, `static method`,
  `static field`, and a computed key evaluating to `"prototype"`), **When** the class is
  evaluated, **Then** a TypeError is thrown.
- **Given** an INSTANCE element keyed `'prototype'` (e.g. `class D{ ['prototype'](){} }`),
  **Then** it installs normally on `D.prototype` (no error).

## In scope
The class machinery in `src/interpreter.zig`: `finishCtorReturn`, `evalClass` constructor
`prototype` property definition, and the static class-element key guard.

## Out of scope
- Per-PrivateName identity / nested-class private shadowing (separate, deeper epic).
- `extends Base` where `Base.prototype` is an accessor getter (`prototype-getter.js`).
- async-method / async-generator-method clusters (owned by the async agent).

## Success criteria
- `language/statements/class` passed: 8067 → 8099 (+32).
- `language/expressions/class` passed: 7596 → 7598 (+2).
- Zero regressions across the full `language/` tree vs `baseline/language.json`.
