# Feature Specification: M4 — Class Definitions

**Feature Branch**: `005-classes`

**Created**: 2026-06-15

**Status**: Draft

**Input**: "M4: classes — the single biggest remaining conformance lever on language/expressions"

## Why (data-driven)
At M3 close, `class/*` is the largest failing bucket in `test/language/expressions`: **2405 unique
failing `class/*` files (≈4762 strict+sloppy executions, ≈39% of all `language/expressions`
failures)**. Classes were deliberately parse-rejected through M3 (`class`/`super`/`extends` reserved
and rejected at parse, §15.7). M4 un-rejects `class` and implements ECMA-262 §15.7 Class Definitions
incrementally, attacking that 39% failure share. Crossing the M3 target of 35% requires classes
first; this milestone is that work.

## User Scenarios & Testing *(mandatory)*
Users: engine devs / CI. Each cycle adds a coherent slice of §15.7, re-measures `language/expressions`
conformance (the `class/*` failure bucket must shrink), runs the mandatory before/after regression
hunt by `mode+path` (un-rejecting `class` converts parse-negatives to reachable-runtime tests — a net
gain is expected but true regressions must be 0 or far outweighed), and stays bench-green (ljs ≤ Node).

### US1 — Class core: declaration/expression, constructor, methods, fields, static, `new` (P1)
`class Name { … }` as a declaration (statement position) and `class { … }` / `class Name { … }` as an
expression (primary position). ClassBody elements: a `constructor(params){…}`; instance methods
`m(params){…}` (installed on `.prototype`); instance fields `x = init;` / `x;` (initialized on each
instance before the constructor body runs); `static` methods and `static` fields (installed on the
constructor object). `new C(args)` runs the constructor with `this` = a fresh instance proto-linked to
`C.prototype`. The class body is always strict (§15.7).
**Test**: `class C {}; new C()` constructs; `class C { constructor(x){ this.x = x; } } new C(7).x` → 7;
`class C { m(){ return 1; } } new C().m()` → 1; `class C { x = 5; } new C().x` → 5;
`class C { static s(){ return 9; } } C.s()` → 9; `class C { static n = 3; } C.n` → 3;
`var C = class { m(){ return 1; } }; new C().m()` → 1.

### US2 — Inheritance: `extends`, `super(...)`, `super.method()` / `super.prop` (P1)
`class D extends C { … }` sets `D.prototype.[[Prototype]]` = `C.prototype` and `D.[[Prototype]]` = `C`.
A derived `super(...)` calls the parent constructor with the current `this`; `super.x` / `super.m()`
look up the home object's prototype.
**Test**: `class A { constructor(){ this.a = 1; } } class B extends A { constructor(){ super(); this.b = 2; } }`
`var o = new B(); o.a + o.b` → 3; `class A { m(){ return 1; } } class B extends A { m(){ return super.m() + 1; } } new B().m()` → 2.

### US3 — Accessors, computed names, method shorthand edge cases (P2)
`get x(){…}` / `set x(v){…}` in a class body (instance + static); computed method/field names
`[expr](){…}` / `[expr] = v;`; method-shorthand edge cases (reserved-word method names, numeric keys).
**Test**: `class C { get v(){ return 7; } } new C().v` → 7;
`class C { ['m'](){ return 1; } } new C().m()` → 1.

### US4 — Private fields/methods `#x`; `static {}` init blocks (P3)
`#field` / `#method()` (private names scoped to the class body, accessed via `this.#x`); `static { … }`
initialization blocks (run once, in order, at class definition with `this` = the constructor).
**Test**: `class C { #x = 5; get(){ return this.#x; } } new C().get()` → 5;
`class C { static x; static { this.x = 9; } } C.x` → 9.

### US5 — Early Errors + close (P3)
The §15.7.1 Early Errors that newly-parseable class syntax exposes: duplicate `constructor`,
`constructor` declared as a getter/setter/generator/async/field, `prototype` as a static method name,
`#constructor` as a private name, a private-name reference with no matching declaration, etc. Then
record the conformance baseline and close the milestone.
**Test**: `class C { constructor(){} constructor(){} }` → SyntaxError;
`class C { get constructor(){} }` → SyntaxError; `class C { static prototype(){} }` → SyntaxError.

### Edge Cases
- A class with no explicit `constructor` gets a default (derived: `constructor(...args){ super(...args); }`).
- Instance fields initialize in declaration order, before the (non-derived) constructor body.
- `class` body is strict even with no directive; `this` inside a method is the receiver.
- A ClassExpression's name binds *inside* the class body (self-reference) but not the outer scope.

## Requirements *(mandatory)*
- **FR-001**: Lex + parse `class Name? (extends LHS)? { ClassBody }` as both a declaration and an
  expression. `static` is contextual (lexed as an identifier, treated specially in class-body parsing).
- **FR-002**: Build a `Class` AST (name, optional superclass, list of class elements tagged
  method/field/static + key + function/initializer + is_static + kind), with a class-declaration Stmt
  and a class-expression Node.
- **FR-003**: §15.7.14 ClassDefinitionEvaluation — create the constructor function object (explicit or
  default), install instance methods on `.prototype`, static methods/fields on the constructor;
  initialize instance fields on each `new` instance per spec ordering; bind the class name in scope.
- **FR-004** (US2): `extends`/`super` — prototype chaining for inheritance, super-constructor call,
  super property/method lookup via the home object.
- **FR-005**: The class body parses in strict context (§15.7), so the M3 strict Early Errors apply.
- **FR-006**: Spec-clause citations on every new production / abstract operation (Principle III).
- **FR-007**: ljs ≤ Node on the bench (absolute pre-commit gate); no M0/M1/M2/M3 regression.
- **FR-008**: Un-rejecting `class` must NOT net-regress: parse-negative class tests that now parse OK
  must either newly pass at runtime, or remain rejected via a still-enforced Early Error / an
  unsupported-syntax parse error. Net gain expected; true regressions (by mode+path) ≤ recoveries.

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `passed` rises above the 4611 M3 baseline (re-measured each cycle,
  bare gate). The `class/*` failure bucket shrinks materially as cycles land.
- **SC-002**: ≥8 class unit tests pass per cycle (decl/expr, constructor+field, method, field init,
  static method, static field, class expression — plus inheritance/accessor/private as cycles land).
- **SC-003**: M0/M1/M2/M3 tests still green (`zig build test` exit 0); bench green (ljs ≤ Node); no
  leaks under the testing allocator. No net regression on the mode+path diff (FR-008).

## Assumptions
- Tree-walk tier retained; this is parser + evaluator + object-model work, not a new tier.
- Generators (`*`), async methods, and the full iteration protocol inside classes are deferred to
  their own later milestones; class-body elements using them parse-reject (preserving negatives) until
  then.

## Dependencies
- M1 engine (functions, `this`, `new`, prototypes), M2 arrays/strings, M3 parser/syntax (params,
  patterns, strict-mode context, object-literal method/accessor model). Test262 harness; bench gate.
  ECMA-262 §15.7.
