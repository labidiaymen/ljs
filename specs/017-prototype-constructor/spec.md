# M16 — `Constructor.prototype.constructor === Constructor` (§19/§20/§22/§23/§27)

## Goal
Every constructor's `.prototype` object must carry an own `constructor` back-reference pointing
to the constructor, with descriptor `{ writable:true, enumerable:false, configurable:true }`
(§19/§20.x.3 step "Constructor.prototype.constructor"). This is the single highest-leverage
conformance fix outstanding: Test262's `assert.throws` checks
`thrown.constructor !== expectedErrorConstructor`, so EVERY `assert.throws(SomeError, …)` test
fails today because a thrown `TypeError` resolves `e.constructor` to `undefined`
(its prototype has no `constructor`). 4,405 of the 12,521 failing `language/` files (35%) use
`assert.throws` or `.constructor`.

Verified pre-state: `[].constructor === Array` → false, `({}).constructor === Object` → false,
`(function(){}).constructor === Function` → false,
`(()=>{try{null.x}catch(e){return e.constructor===TypeError}})()` → false.

## Scope (ECMA-262, no host APIs)

### Built-in constructors (`src/builtins.zig`)
Set `<Ctor>.prototype.constructor = <Ctor>` (writable, NON-enumerable, configurable) for:
- `Object` (§20.1.2.1 → `Object.prototype.constructor === Object`), `Function`
  (%Function.prototype%.constructor === Function), `Array`, `String`, `Symbol`, `Promise`.
- The whole Error family: `Error`, `TypeError`, `RangeError`, `ReferenceError`, `SyntaxError`,
  `EvalError`, `URIError`, and `AggregateError` (§20.5.6.3.1 / §20.5.3.1).
- `Math`/`JSON` are namespaces, not constructors — skipped (no `.prototype`).
- The generator / async-generator intrinsic prototypes are NOT constructible from a global
  binding and have no spec `constructor` data property of this kind (their `constructor` is the
  %Generator% function object, not installed in the M-subset) — deferred.

Because thrown engine errors (`throwError`) are proto-linked to `<NativeError>.prototype`, once
that prototype has `constructor`, `e.constructor` resolves through the chain — no interpreter
change needed for the throw path.

### User functions (`src/interpreter.zig`)
When an ordinary function object's `.prototype` is created (§10.2.4 MakeConstructor /
OrdinaryFunctionCreate), set `prototype.constructor = theFunction`
(writable, non-enumerable, configurable). Applies at both creation sites: function declarations
(`func_decl`) and function expressions / non-arrow (`evalFunctionExpr`). Arrows have no
`.prototype`, so they are skipped. So `function F(){}; F.prototype.constructor === F` and
`new F().constructor === F`.

### Classes (`src/interpreter.zig` `evalClass`)
Already correct: `evalClass` defines `proto.constructor = ctor` non-enumerable. Covered by an
added regression test (`class C{}; new C().constructor === C`).

### `Object.prototype.constructor`
Set explicitly so `({}).constructor === Object` resolves through the chain for any object that
inherits from `Object.prototype`.

## Out of scope / deferred
- %GeneratorPrototype% / %AsyncGeneratorPrototype% / %IteratorPrototype% `constructor` (the
  intrinsic %Generator% function object is not exposed in the M-subset).
- Per-realm well-formedness beyond the descriptor attributes above.

## Gates
Primary: `language/` harness `passed ≥ 21378` (expect a large gain — unblocks `assert.throws`
suite-wide). Continuity: `language/expressions ≥ 10327`. Watch: a stray ENUMERABLE `constructor`
would break for-in / `Object.keys` tests — it MUST be non-enumerable. Bench: no ljs-vs-self
regression (the built-in `constructor` is one insert per prototype at realm setup; the
user-function `constructor` is one insert per function object at creation, outside hot loops).
