# 030 — Eager generator/async-generator parameter instantiation (§15.5.2 / §15.6.2)

## Problem
ljs bound a generator's parameters (destructuring patterns, default-value expressions, the
`arguments` object) LAZILY — on the body thread, at the first `.next()` — instead of EAGERLY at
the call site. Per ECMA-262 the body of a generator is suspended at its *start*, but
FunctionDeclarationInstantiation (binding the formals) is NOT part of the suspended body: it runs
when `[[Call]]` evaluates the generator body, before the Generator/AsyncGenerator object is created
and returned. So a parameter destructuring/default error must surface at the CALL site, not at
`.next()`.

Symptom: any `function*` / `async function*` (incl. class generator methods, static or private)
whose params have a throwing default, an unresolvable reference, a non-iterable destructured value,
or an iterator-protocol error (`iter-step-err`, `iter-val-err`, `init-throws`, `obj-init-null`,
`obj-ptrn-rest-skip-non-enumerable`, …) failed: the error either never threw, or threw at the wrong
time. Concretely:

```js
function* g([x = (function(){ throw new Error("boom"); })()]) {}
g([undefined]);          // must THROW here; ljs deferred → no throw until .next()

async function* ag([x = (function(){ throw new Error(); })()]) {}
ag([undefined]);          // must THROW synchronously at the call (V8 parity)
```

This is the single systematic cause behind the large `statements/class/dstr` and
`expressions/class/dstr` `gen-meth` / `async-gen-meth` / `private-gen-meth` buckets and the
`statements|expressions/{generators,async-generator}` param-error tests.

## Spec clauses
- **§15.5.2 Runtime Semantics: EvaluateGeneratorBody** — step 1:
  `Perform ? FunctionDeclarationInstantiation(functionObject, argumentsList).` This runs (and may
  throw) BEFORE step 2 (`OrdinaryCreateFromConstructor` → the Generator object) and step 4
  (`GeneratorStart`). A param abrupt completion therefore propagates out of `[[Call]]` synchronously.
- **§15.6.2 Runtime Semantics: EvaluateAsyncGeneratorBody** — same shape: step 1
  `FunctionDeclarationInstantiation` runs eagerly; an abrupt completion throws at the call site (the
  AsyncGenerator object is never created), matching V8.
- **§27.5.3.3 / §27.6.3.x** — only the FunctionBody (statements after binding) is what suspends at
  `suspended_start` and resumes on `.next` / a request.
- **Contrast — §27.7.5.1 Async Functions:** an async function ALSO binds params eagerly per spec,
  but a param error there REJECTS the returned promise (it does not throw at the call site). ljs
  keeps async-function param binding on the body thread (the body's throw completion already rejects
  the promise), so that path is unchanged and remains correct.

## Fix
`src/interpreter.zig`:
- Factor the param-binding loop out of `runGeneratorBody` into
  `instantiateGeneratorParams(gen, *?Completion) -> *Environment` (FunctionDeclarationInstantiation:
  params + defaults + destructuring + rest + `arguments`), returning a thrown completion via an
  out-param.
- `createGenerator` and `createAsyncGenerator` now call it EAGERLY on the caller thread, store the
  resulting environment on `gen.call_env`, and return the abrupt completion (so the call throws)
  before the generator object is created.
- `runGeneratorBody` reuses `gen.call_env` when present (generators); when null (async functions) it
  binds on the body thread as before, preserving the promise-rejection semantics.

`src/object.zig`: add `Generator.call_env: ?*Environment` (the eagerly-bound environment; null for
async functions).

## Non-goals / parity preserved
- Ordinary (non-generator) `[[Call]]` is untouched.
- Async function param-error → promise rejection is untouched.
- `this` / `home_object` visibility inside default-param expressions is unchanged (the body still
  sets `self.this_val` / `self.home_object` from the generator after binding, exactly as before).
