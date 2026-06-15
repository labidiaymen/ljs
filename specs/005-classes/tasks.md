---
description: "Task list for M4 — class definitions (§15.7, conformance-driven)"
---

# Tasks: M4 — Class Definitions

**Metric (from M4 Cycle 2 onward):** conformance is now reported **WITH the Test262 harness prelude**
(`--harness-dir vendor/test262/harness`, the standard Test262 way). The prior bare-gate numbers
undercounted positive tests that call `assert.*`. Same code at commit `9320218`: bare **27.2%** =
harness **32.3%** on `language/expressions` (passed 4,622 → 5,484). The committed baseline
`baseline/language-expressions.json` and all deltas below use the harness metric.

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

## Cycle 2 — Inheritance: `extends` + `super(...)` + `super.x` / `super.m()` (US2) 🎯 (DONE — harness metric: passed 5484 → 5526, +42 net, 0 true regressions; conformance 32.3% → 32.6%)
- [x] M4-T020 Wire the superclass: `B.prototype.[[Prototype]]` = `Super.prototype`, `B.[[Prototype]]` =
  `Super` (§15.7.14 — static inheritance); `extends null` → `B.prototype.[[Prototype]]` = null. A
  derived `super(...)` (§13.3.7 SuperCall) calls the parent constructor with the current `this`; the
  default derived constructor forwards its args to `super(...)`. `super.x` / `super.m()` (§13.3.5
  SuperProperty) look up the active method's [[HomeObject]].[[Prototype]] but invoke with `this` = the
  current `this`. `super` is un-rejected inside method/derived-constructor bodies.
  - **AST (`src/ast.zig`):** new `Node.super_call: []const *const Node` (SuperCall args) and
    `Node.super_member: { name, key }` (SuperProperty `super.x` / `super[expr]`).
  - **Object model (`src/object.zig`):** `FunctionData` gains `home_object: ?*Object` (the object a
    method is defined on — instance method → `.prototype`, static method → the constructor; the
    constructor's home is the `.prototype`), `is_derived_ctor`, and `super_ctor` (the linked parent
    constructor, used by `super(...)`).
  - **Parser (`src/parser.zig`):** two context flags — `in_method` (a MethodDefinition/field-init body
    has a [[HomeObject]] → `super.x` allowed) and `in_derived_ctor` (only a derived class's
    `constructor` → `super(...)` allowed). `parseFunction` resets both to false (an ordinary nested
    function has no home / is not a constructor); arrows DELIBERATELY keep them (lexical `super`, like
    `this`). `super` is handled in `parsePostfix` (it is always the base of `.`/`[]`/`()`); a bare
    `super` or a `super`/`super(...)` outside its allowed context is a SyntaxError (§13.3.5.1 /
    §13.3.7.1 Early Errors — these keep the negative-parse tests rejecting, so un-rejecting `super`
    nets 0 regressions).
  - **Interpreter (`src/interpreter.zig`):** `evalClass` evaluates `extends`, links the prototype
    chains, sets each method's `home_object`, sets `proto.constructor`, and records the derived ctor's
    `super_ctor`/`is_derived_ctor`. The interpreter carries the active `home_object` (set in
    `callFunction` per call, inherited by arrows). `super.x` resolves against
    `home_object.[[Prototype]]` with `this` = the receiver (getters honored); `super.m(args)` calls
    with `this` = the current `this`. `super(...)` runs the parent ctor on the existing `this` (a base
    parent inits its fields before its body), then the derived class's own fields (§15.7.14 ordering:
    derived fields after `super()`). `evalNew` skips upfront field-init for derived classes and
    synthesizes the implicit `super(...args)` + field-init for a default derived constructor.
  - **Tests (`src/engine.zig`):** `class A{constructor(){this.x=1}} class B extends A{constructor(){
    super();this.y=2}} new B().x+new B().y` → 3; `super.m()` calling the parent method; `b instanceof A`
    + `b instanceof B`; `super.prop` reading the parent prototype data prop; static inheritance
    (`B.s()` / `B.n`); default derived ctor arg-forwarding; `extends` an expression; a 3-level chain;
    derived fields after `super()`; `extends null`; and the §13.3.5.1/§13.3.7.1 Early-Error negatives.
  - **Conformance + regression hunt (harness metric):** `passed 5484 → 5526` (+42 net), conformance
    32.3% → 32.6%. **0 true regressions** by `mode+path` (`comm` before/after, ReleaseFast); 42
    recoveries — all super/extends-related: `super/prop-dot-cls-val*`, `super/prop-expr-cls-val*`,
    `super/call-*`, `super/super-reference-resolution`, `arrow-function/lexical-super*` (confirming
    arrows inherit `super` lexically), and `class/subclass-builtins/subclass-{Array,Error,Object,…}`.
    Baseline gate green ("no regression vs baseline"). Bench green (loop_mix −5.2%, loop_sum −5.6%,
    str_build −4.4%; perf ok, ljs 0.2–0.5× Node — the super/home-object additions are off the hot path).
  - **Landed:** `extends Expr` + prototype/static-inheritance linking + `extends null`; `super(...)` in
    a derived constructor (explicit + default); `super.x` / `super[k]` / `super.m(args)` via
    [[HomeObject]]; lexical `super` in arrows; derived-class field ordering (after `super()`); the
    §13.3.5.1/§13.3.7.1 Early Errors; `extends` a non-constructor/non-null → runtime TypeError.
    **Deferred:** accessors/computed names (Cycle 3); private `#x` + static blocks (Cycle 4); the
    remaining §15.7.1 Early Errors (Cycle 5). Subclassing built-ins links the chains but does not yet
    install exotic internal slots (the positive value-checks that recovered are prototype-chain ones).

## Cycle 3 — Accessors, computed names, method-shorthand edges (US3) 🎯 (DONE — harness metric: passed 5526 → 5766, +240 net, 0 true regressions; conformance 32.6% → 34.0%)
- [x] M4-T030 `get x(){…}` / `set x(v){…}` in a class body (instance + static), reusing the §13.2.5.6
  accessor model; computed method/field/accessor names `[expr](){…}` / `[expr] = v;` / `get [expr](){…}`
  (key evaluated at class definition, in definition order).
  - **AST (`src/ast.zig`):** no change needed — Cycle 1 already provisioned `ClassElementKind.get`/`.set`
    and `ClassElement.computed_key` (`?*const Node`). This cycle wires them through the parser + evaluator.
  - **Parser (`src/parser.zig`):** `parseClassElement` no longer parse-rejects `get`/`set` (when followed
    by a PropertyName); a new `parseClassAccessor` mirrors the object-literal §13.2.5.6 accessor path —
    accessor arity Early Errors (getter takes 0 params, setter exactly 1, no rest), [[HomeObject]] context
    (`in_method = true`, `in_derived_ctor = false`) so `super.x` is allowed but `super(...)` is not, and the
    §15.7.1 name restrictions (`constructor` may not be a getter/setter; a `static` accessor named
    `prototype` is forbidden). Computed keys flow through the existing `parsePropertyName` `[expr]` branch
    (already used by methods/fields since Cycle 1) — only generators (`*m`) and async are still rejected.
  - **Interpreter (`src/interpreter.zig`):** `evalClass` is now a single definition-order pass over
    `c.elements`: a new `classElementKey` helper evaluates a computed `[expr]` key (ToPropertyKey →
    ToString) at class-definition time interleaved with the other elements (so key side-effects observe
    definition order); `.get`/`.set` elements install via `defineAccessor` on `.prototype` (instance) or
    the constructor (static), merging a get+set pair for the same key into one accessor property, and carry
    [[HomeObject]] (= the install target) so `super.x` works inside an accessor; instance-field records are
    collected during the pass (with their resolved keys) and attached to the constructor's
    `FunctionData.fields` afterward (the constructor is built first with empty fields, then mutated). The
    object-model `PropertyValue.accessor` + `defineAccessor` (M3 C6) and computed-key eval (`propKey`) are
    reused as-is.
  - **Tests (`src/engine.zig`):** `get x(){return 5}` → `.x` is 5; `set x(v)` stores; a get+set pair
    round-trips; setter-only; static `get`/`set`; `super.x` inside a derived getter; computed method
    `['a'+'b'](){return 1}` → `new C().ab()`; computed instance + static fields; bare computed field;
    computed getter/setter; definition-order key-eval (`[a()][b()]` → "ab"); numeric computed key ToString.
    The Cycle-1 "unsupported syntax still rejects" test was updated to drop `get`/`set` (now supported) and
    add `static *m`, `async m`, `async *m` (still rejected — generators/async are a separate milestone).
  - **Conformance + regression hunt (harness metric, ReleaseFast):** `passed 5526 → 5766` (+240 net),
    conformance 32.6% → 34.0%. **0 true regressions** by `mode+path` (`comm` before/after); 240 recoveries
    — 236 `class/*` (`accessor-name-inst/*` + `accessor-name-static/*` accessor positives, `cpn-*`
    computed-property-name positives, plus `scope-{static-,}setter-paramsbody-*`) and 4 `super/*`. The
    generator/async class negatives still parse-reject (they are in the 0-regression set). Baseline gate
    green ("no regression vs baseline"). Bench green (loop_mix −8.0%,
    loop_sum −7.7%, str_build −11.0%; perf ok, ljs 0.2–0.5× Node — the accessor/computed-key work is off
    the hot path).
  - **Landed:** instance + static `get`/`set` accessors (get+set merge, [[HomeObject]] for `super`);
    computed method/field/accessor names evaluated at class-definition time in definition order. **Deferred:**
    private `#x` + static blocks (Cycle 4); the remaining §15.7.1 Early Errors (Cycle 5); generator/async
    methods (separate future milestone — kept parse-rejecting).

## Cycle 4 — Private names + static blocks (US4) 🎯 (DONE — harness metric: passed 5766 → 6077, +311 net, 4 true regressions far outweighed by 315 recoveries; conformance 34.0% → 35.8%)
- [x] M4-T040 Private fields/methods `#x` (private names lexically scoped to the class body, accessed
  via `this.#x` / `obj.#x`; §15.7 PrivateName semantics) and `static { … }` initialization blocks
  (§15.7.11, run once in order at class definition with `this` = the constructor).
  - **Lexer (`src/lexer.zig`):** a new `private_identifier` token for `#name` (a `#` immediately
    followed by an IdentifierName; the lexeme INCLUDES the `#`, so private and public keys never
    collide). A bare `#` not followed by an identifier start is an `UnexpectedCharacter` (→ SyntaxError).
  - **AST (`src/ast.zig`):** `Node.private_member` (`obj.#x` read), `Node.private_assign` (`obj.#x = v`),
    `Node.private_in` (the §13.10.1 brand check `#x in obj`); `ClassElementKind.static_block`;
    `ClassElement.is_private` + `ClassElementValue.block` (static-block body).
  - **Object model (`src/object.zig`):** `Object.private_fields` — a per-object `StringHashMapUnmanaged`
    keyed by `#name`, LAZILY allocated (only objects with private members ever pay for it, so the
    ordinary `obj.x` path is untouched — bench-confirmed). Private members are stored as `PropertyValue`
    (data for fields/methods, accessor for get/set) and are NEVER reachable via `[[Get]]`/`[[Set]]`/`in`
    (privacy by storage). Helpers `hasPrivate`/`getPrivate`/`setPrivate`/`definePrivate(Accessor)`.
    `FunctionData` gains `private_elements: []const PrivateElement` (the ctor's per-instance brand —
    fields/methods/accessors, installed on each `new`) and `is_private_method` (a private method slot is
    read-only). `PrivateElement` carries the `#name`, a kind, an init node (field) or a shared `*Object`
    (method/getter/setter, [[HomeObject]] set).
  - **Parser (`src/parser.zig`):** `#name` class elements (instance/static `#x` field, `#m(){}` method,
    `get/set #x(){}` accessor); `static { … }` blocks (`parseStaticBlock`, a method-like context —
    `super.x` ok, `super()` not). `obj.#x` member access in `continuePostfix`; `obj.#x = v` /
    `obj.#x op= v` / `obj.#x++` assignment targets; `#x in obj` in `parseExpr` (relational level).
    Two context flags: `in_class_body` (a `#x` reference outside a class is a SyntaxError) and
    `in_static_block` (§15.7.11 — `await` is reserved as a BindingIdentifier/IdentifierReference inside
    a static block; reset in nested ordinary functions, inherited by arrows). §15.7.1 Early Errors that
    the now-parseable `#` exposes — all added to keep the parse-negatives rejecting: **AllPrivateNamesValid**
    (every `#x` reference must resolve to a declared private name in an enclosing class — a per-class-body
    token PRE-SCAN `collectClassPrivateNames` collects PrivateBoundNames so forward references resolve);
    `#constructor` forbidden; duplicate private names (one PrivateEnvironment per class shared by
    static+instance — only a same-placement get/set pair may repeat); `delete obj.#x` (even covered
    `delete (obj.#x)`) is a SyntaxError (§13.5.1.1); a `#x` in an object literal rejects.
  - **Interpreter (`src/interpreter.zig`):** `evalClass` installs static private members on the ctor's
    private slot at definition time, runs `static { }` blocks in source order (interleaved with static
    fields, `this` = ctor, [[HomeObject]] = ctor), and records instance private elements +
    instance-field records on the ctor's `FunctionData`. `initInstanceFields` now first installs the
    private brand (`installPrivateElements` — private methods/accessors are shared, private fields' inits
    run with `this` = the instance, in declaration order so a field init can call an earlier `#m`).
    `getPrivate`/`setPrivate` enforce the brand: a missing private slot (or a non-object) is a runtime
    **TypeError**; a private method slot is read-only; private accessors invoke get/set with `this` =
    receiver. `private_in` is the no-throw boolean brand check. `obj.#m()` calls with `this` = `obj`.
  - **Tests (`src/engine.zig`):** private fields (read/reassign/compound, undefined default, no
    collision with same-named public prop, not enumerable); brand-check TypeError on a foreign
    object/primitive (read + write); private methods (read-only) + private get/set accessors (incl. a
    field init calling an earlier `#m`, and inheritance adding each class's own brand); static private
    members (method/field/accessor); static `{ }` blocks (order, interleave with static fields,
    `super.x`); `#x in obj` (true/false/non-object, private-method name); private-name early errors
    (`#x` outside a class, bare `#`, `#constructor`, duplicates, get/set-pair allowed, object-literal `#x`).
  - **Conformance + regression hunt (harness metric, ReleaseFast):** `passed 5766 → 6077` (+311 net),
    conformance 34.0% → 35.8%. **4 true regressions** by `mode+path` (`in/private-field-in{,-nested}`
    ×2 modes — `for (#field in value;;)` needs the for-in `[~In]` grammar, and this engine has no
    for-in; deferred), far outweighed by **315 recoveries** — `class/dstr` (192, class-destructuring
    positives that now parse cleanly), `class/elements` private features (28 + 12 private-accessor-name),
    `logical-assignment` (34) / `compound-assignment` (24) reaching private-member targets,
    `class/elements/syntax/valid` (10), `in` brand-check positives (8). The naive un-rejection of `#` /
    `static{}` FIRST measured 238 regressions (newly-parseable `#` un-rejected the §15.7.1 Early-Error
    negatives); adding AllPrivateNamesValid + `delete #x` + duplicate-across-placement + `await`-in-
    static-block dropped it to 4. Generator/async class negatives still parse-reject (in the 4-regression
    set, untouched). Bench green (loop_mix −13.6%, loop_sum −13.2%, str_build −13.2%; perf ok, ljs
    0.2–0.5× Node — private storage is a separate lazily-allocated map, off the ordinary property path).
  - **Landed:** instance + static private fields/methods/accessors (`#x`, `#m(){}`, `get/set #x(){}`)
    via a per-instance private slot with TypeError brand checks; `static { }` initialization blocks (in
    source order, `this` = ctor); `#x in obj` brand check; the §15.7.1 Early Errors the new syntax
    exposes (AllPrivateNamesValid, `#constructor`, duplicate private names, `delete #x`, `await` in a
    static block). **Deferred:** the remaining §15.7.1 Early Errors (Cycle 5); generator/async methods
    (separate milestone — kept parse-rejecting); `for (#x in obj;;)` rejection (needs for-in support).

## Cycle 5 — Early Errors + close (US5) 🎯 (DONE — harness metric: passed 6077 → 6077, 0 net, 0 true regressions; conformance 35.8% → 35.8%)
- [x] M4-T050 **§15.7.1 class Early Errors audit — already complete.** A `grep`-driven sweep of the
  remaining failing `class/*` negative tests (the prompted methodology) found that **every §15.7.1
  parse-phase Early Error the now-parseable class syntax exposes was already enforced across Cycles
  1/2/4**, and the `class/elements/syntax/early-errors` subtree passes **444/444 (100%)**. Each candidate
  from the §15.7.1 / §15.7.5.1 list was probed directly and confirmed rejecting (parse SyntaxError):
  - duplicate (non-static) `constructor` — `parser.zig` ClassBody post-parse scan (Cycle 1);
  - `constructor` as a getter/setter — `parseClassAccessor` name check (Cycle 3);
  - `constructor` as a field (incl. string-named `"constructor" = …`) — `parseClassElement` field check (Cycle 1);
  - `static prototype` as method / accessor / field — `parseClassElement` + `parseClassAccessor` (Cycles 1/3);
  - `#constructor` private name + duplicate private names + unresolved `#x` (AllPrivateNamesValid) — Cycle 4.
  These were confirmed as **correct positives, NOT rejected** (over-rejection guards): a `static
  constructor` STATIC method, a `static get constructor` accessor, a non-static method/accessor named
  `prototype`, a computed `["constructor"]()` method (keys off the *static* StringValue, so it is an
  ordinary method, no clash), `;` empty class-body elements, and `extends <bad target>` (a **runtime**
  TypeError, not a parse Early Error). No new parser code was needed; Cycle 5 adds a dedicated
  `engine.zig` test block ("§15.7.1 class early errors + legal positives (Cycle 5, close)") asserting
  both the Early-Error rejections and the legal-positive non-rejections so the boundary stays pinned.
  - **Investigated but DEFERRED (out of M4 scope):** the large residual `class/*` `parse_error` bucket is
    blocked by `vendor/test262/harness/propertyHelper.js`, which uses a **`for (… in …)` loop** the engine
    does not yet parse (for-in is its own milestone). A `§14.4 EmptyStatement` (`;`) fix was prototyped (a
    lone statement-level `;` is currently parse-rejected) — it is spec-correct but **un-masks** out-of-scope
    async-function and `for`-header `[In]`-grammar gaps, netting −8 (12 negative tests that were passing only
    *incidentally* via a trailing-`;` parse error flip to genuine runtime failures), and it recovers **zero**
    `class/*` tests (the class positives that use `;` are all also for-in-harness-blocked). Per the gate
    ("do NOT commit a net regression"; "don't chase async/for-in"), the EmptyStatement change was reverted and
    is left for the §14.4 / async / for-in milestones.
- [x] M4-T051 Refreshed the conformance baseline (SC-001, `baseline/language-expressions.json`), updated
  README/roadmap (M4 marked done at 35.8%), confirmed all gates green (build/test/lint 0/0; bench
  `perf: ok (no ljs-vs-self regression)`, ljs 0.2–0.5× Node) and **0 true regressions vs HEAD `b514b79`
  by `mode+path`**; M4 closed.

## M4 milestone — CLOSED ✅
**Class conformance journey (`language/expressions`, harness metric):**
| Cycle | Slice | passed | conformance | net |
|------|-------|-------:|------------:|----:|
| (start, `9320218`) | M3 close, classes parse-rejected | 5484 | 32.3% | — |
| C1 | class core (decl/expr, ctor, methods, fields, static, `new`) | 5484 | 32.3% | +0* |
| C2 | `extends` + `super(…)` / `super.x` | 5526 | 32.6% | +42 |
| C3 | accessors `get`/`set` + computed names | 5766 | 34.0% | +240 |
| C4 | private `#x` (fields/methods/accessors) + `static {}` blocks | 6077 | 35.8% | +311 |
| C5 | §15.7.1 Early-Errors audit + close | 6077 | 35.8% | +0 |
| **Total** | **M4 classes** | **5484 → 6077** | **32.3% → 35.8%** | **+593** |

\* C1 measured +0 on the harness metric line at the cadence-change commit; the class subtree gained
~+230 once re-measured (the bare-vs-harness metric switch landed the same cycle). The **+593** total is
the honest M4 delta on the harness metric from M3 close to M4 close.

**Landed (full §15.7 surface):** ClassDeclaration + ClassExpression; explicit/default `constructor`
(base + derived); instance methods on `.prototype`; instance fields (pre-ctor init order); `static`
methods/fields; `new C(args)`; `extends Expr` + prototype/static inheritance + `extends null`;
`super(…)` / `super.x` / `super[k]` / `super.m()` via [[HomeObject]] (lexical in arrows); instance +
static `get`/`set` accessors (get/set merge); computed method/field/accessor names (definition-order
key eval); private fields/methods/accessors `#x` with TypeError brand checks; `#x in obj` brand check;
`static { … }` initialization blocks; named-class-expression self-reference; class body always strict;
and the §13.3.5.1/§13.3.7.1/§15.7.1 parse-phase Early Errors the new syntax exposes.

**Known deferred gaps (separate future milestones):**
- Generator (`* m`) and `async` methods inside classes — still parse-reject (preserves their negatives).
- `for (#x in obj)` / `for (… in …)` — the engine has no for-in yet (4 `in/private-field-in*` true-
  regressions from C4 still stand; also blocks the positive `class/*` tests whose harness include
  `propertyHelper.js` uses `for-in`, and the `§14.4 EmptyStatement` recovery).
- `async function` / `async` arrow at statement/expression level — parse as a bare `async` identifier
  rather than rejecting; rejecting them would recover the C5 EmptyStatement async un-masking but is
  async-milestone work.
- Subclassing built-ins links the prototype chains but does not install exotic internal slots.
- Unicode-escape identifiers (`\u{6F}` etc.) and the `accessor` auto-accessor keyword — lexer features,
  not class Early Errors.

## Dependencies / order
Ordered by impact-to-effort and spec layering: class core first (the constructor/method/field/static
object-model + `new` path — the bulk of the 39% bucket), then inheritance (`extends`/`super`), then
accessor/computed-name sugar, then private names + static blocks, then the Early Errors that the now-
reachable syntax exposes. Each cycle bench-gated; each cycle runs the before/after regression hunt.
