---
description: "Task list for M4 — class definitions (§15.7, conformance-driven)"
---

# Tasks: M4 — Class Definitions

**Cadence**: one cycle = one coherent slice of §15.7 = one commit (build + test + lint + **bench
(ljs ≤ Node)** green). Re-measure `language/expressions` each cycle (the `class/*` failure bucket must
shrink). Plan folded into the spec (parser + evaluator + object-model work; no new architecture tier).

**Mandatory regression hunt (every cycle):** un-rejecting `class` converts parse-negative tests into
reachable-runtime tests. Capture `grep "^  fail"` (by `mode+path`) before and after each change;
true-regressions must be 0 or far outweighed by recoveries. If un-rejecting class nets a regression
(parse-negatives now parse-OK-but-don't-throw), either implement enough to net-positive OR keep the
specific Early Errors / unsupported-syntax parse rejections so those tests still reject.

## Cycle 1 — Class core: decl/expr, constructor, methods, fields, static, `new` 🎯 (DONE — passed 4611 → 4622, +11 net bare-gate, 0 true regressions)
- [x] M4-T010 **Un-reject `class`** (replace the §15.7 parse-rejection from M3 Cycle 5) and parse
  `class Name? (extends LHS)? { ClassBody }` as BOTH a ClassDeclaration (statement position) and a
  ClassExpression (primary position). ClassBody elements supported this cycle: `constructor(params){…}`,
  instance method `m(params){…}`, instance field `x = init;` / `x;`, `static m(){…}`, `static x = init;`.
  The class body parses in **strict** context (§15.7 — `self.strict = true` inside the body, lexically
  inherited like a function body). Reuses `parseParams`/`parsePattern`/`parsePropertyName`/`parseMethodBody`.
  - **AST (`src/ast.zig`):** new `Class` (name, optional `superclass: ?*const Node`, `elements:
    []const ClassElement`), `ClassElement { kind: method|field, is_static, key, computed_key, value:
    ?*const Function (method) / initializer (field) }`, `ClassElementKind { method, get, set,
    constructor, field }`. New `Stmt.class_decl: *const Class` + `Node.class_expr: *const Class`.
  - **Object model (`src/object.zig`):** the constructor is an ordinary `createFunction` function object
    whose `.call` is the (explicit or default) constructor body; its `.prototype` carries the instance
    methods; static methods/fields go on the constructor object. `FunctionData` gains `fields:
    []const ClassFieldInit` (the instance field initializers, run on each `new`) and `home_object`
    (the `.prototype` for method `super` lookup, wired in Cycle 2).
  - **Evaluate (`src/interpreter.zig`, §15.7.14 ClassDefinitionEvaluation):** `evalClass` builds the
    constructor (explicit `constructor` body or a default empty body), defines non-static methods on
    `.prototype` (data/accessor like object-literal methods, Cycle-6 model), defines static
    methods/fields on the constructor, stashes instance-field initializers on the constructor's
    `FunctionData`; binds the class name. `evalNew` runs the field initializers on the new instance
    (with `this` = instance) BEFORE the constructor body (§15.7.14 step ordering). A ClassExpression's
    name is bound in an inner scope for self-reference; a ClassDeclaration binds in the current scope.
  - **`extends`/`super` DEFERRED to Cycle 2** (kept scope tight for a clean green Cycle 1). `extends`
    is parsed (so `class X extends Y {}` doesn't parse-reject) but the superclass link + `super` are
    Cycle 2; a `super` token inside a class body still parse-rejects this cycle (preserves the
    `super`-negative class tests). Unsupported class-element syntax (`*` generator, `async`, `get`/`set`
    accessors → Cycle 3, `#private` / `static {}` → Cycle 4) parse-rejects, preserving those negatives.
  - **Tests (`src/engine.zig`):** `class C{}; new C()`; constructor with `this.x` field assignment;
    instance method call; instance field initializer; `static` method; `static` field; class expression
    `var C = class{ m(){return 1} }`. All green via `zig build test`.
  - **Conformance + regression hunt:** bare gate (no harness prelude) `passed 4611 → 4622` (+11 net),
    conformance 27.2% → 27.2% (4622/(4622+12349)=27.2%). **0 true regressions** by `mode+path`, 11
    recoveries (class valid-grammar `grammar-class-body-ctor-no-heritage` / `grammar-fields-multi-line`,
    `class-name-ident-await`, plus the strict-`yield`-as-IdentifierReference rejection recovered
    `arrow-function/param-dflt-yield-id-strict`, `assignmenttargettype/direct-yieldexpression-0`,
    `in/rhs-yield-absent-strict`, `arrow-function/dstr/syntax-error-ident-ref-extends`). The naive
    un-rejection FIRST measured −56 (64 parse-negatives now parse-OK-but-don't-throw); per the gate I
    added the §15.7.1 Early Errors those tests check (FieldDefinition PropName ≠ `constructor`; static
    member ≠ `prototype`; duplicate `constructor`; `arguments` in a field Initializer via
    ContainsArguments; FieldDefinition same-line ASI restriction; strict `yield` reference) →
    net flips to **+11, 0 regressions**. With the harness prelude (informational), the `class/*`
    subtree gains far more: `passed 1202 → 1432` (+230) — the bare gate undercounts the class positives
    that call `assert.*`. The baseline regression gate (`--baseline baseline/language-expressions.json`)
    is green ("no regression vs baseline"). Bench green (loop_mix −11.4%, loop_sum −3.9%, str_build
    −4.2%; perf ok, ljs 0.2–0.5× Node).
  - **Landed this cycle:** ClassDeclaration + ClassExpression; explicit/default `constructor`; instance
    methods on `.prototype`; instance fields (initialized before the constructor body); `static`
    methods + `static` fields; `new C(args)`; class-constructor-without-`new` TypeError (§15.7.14);
    named-class-expression self-reference; class body is strict. **Deferred:** `extends`/`super` link
    (parsed, not yet evaluated — Cycle 2); accessors/computed names (Cycle 3); private `#x` + static
    blocks (Cycle 4); remaining §15.7.1 Early Errors (Cycle 5).

## Cycle 2 — Inheritance: `extends` + `super(...)` + `super.x` / `super.m()` (US2)
- [ ] M4-T020 Wire the superclass: `D.prototype.[[Prototype]]` = `C.prototype`, `D.[[Prototype]]` = `C`
  (§15.7.14). A derived `super(...)` (§13.3.7 SuperCall) calls the parent constructor with the current
  `this`; default derived constructor is `constructor(...args){ super(...args); }`. `super.x` /
  `super.m()` (§13.3.5 SuperProperty) look up the method's home-object prototype. Un-reject `super`
  inside class bodies/methods. Correct prototype chaining for inheritance.

## Cycle 3 — Accessors, computed names, method-shorthand edges (US3)
- [ ] M4-T030 `get x(){…}` / `set x(v){…}` in a class body (instance + static), reusing the §13.2.5.6
  accessor model; computed method/field names `[expr](){…}` / `[expr] = v;` (key evaluated at class
  definition); method-shorthand edge cases (reserved-word + numeric/string keys).

## Cycle 4 — Private names + static blocks (US4)
- [ ] M4-T040 Private fields/methods `#x` (private names lexically scoped to the class body, accessed
  via `this.#x`; §15.7.x PrivateName semantics) and `static { … }` initialization blocks (§15.7.11,
  run once in order at class definition with `this` = the constructor).

## Cycle 5 — Early Errors + close (US5)
- [ ] M4-T050 §15.7.1 Early Errors that newly-parseable class syntax exposes: duplicate `constructor`;
  `constructor` as a getter/setter/generator/async/field; `prototype` as a static method name;
  `#constructor` as a private name; an unresolved private-name reference; etc.
- [ ] M4-T051 Record the conformance baseline (SC-001), update README/roadmap, confirm bench green and
  no M0–M3 regression; close M4.

## Dependencies / order
Ordered by impact-to-effort and spec layering: class core first (the constructor/method/field/static
object-model + `new` path — the bulk of the 39% bucket), then inheritance (`extends`/`super`), then
accessor/computed-name sugar, then private names + static blocks, then the Early Errors that the now-
reachable syntax exposes. Each cycle bench-gated; each cycle runs the before/after regression hunt.
