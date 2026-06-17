# M35 — Hashbang comment + object-method SuperProperty + new.target meta-property (§12.5 / §13.3.5 / §13.3.12)

## Goal
Three bounded parse-gap features, all confirmed `parse_error` clusters in `language/`:

1. **§12.5 HashbangComment** — a `#!` at the very start of the Script is a line comment.
2. **§13.3.5 / §13.2.5 SuperProperty in object-literal methods** — object-literal methods /
   accessors / generator / async methods have a [[HomeObject]] and may use `super.x` / `super[k]`.
3. **§13.3.12 NewTarget meta-property** — `new.target` reads the active function's [[NewTarget]].

## Rules implemented

### 1. HashbangComment (§12.5)
- A `#!` at source offset 0 (before ANY token or whitespace) begins a HashbangComment that runs to
  the end of the line (like a `//` SingleLineComment), terminating at `\n` / `\r` / U+2028 / U+2029.
- Only the leading `#!` of a Script is a hashbang. A `#!` anywhere else (even after leading
  whitespace or a newline) is NOT a hashbang — the `#` there is a PrivateIdentifier outside a class,
  i.e. a SyntaxError (unchanged behavior).
- Implemented in the lexer (`Lexer.init`) — consumed before the first `next()`, so the parser never
  sees it. `#!/usr/bin/env node\n42` evaluates `42`.

### 2. SuperProperty in object-literal methods (§13.3.5 / §13.2.5)
- An object-literal method / accessor / generator-method / async-method has a [[HomeObject]] = the
  object literal, so `super.x` and `super[k]` are legal in its PARAMS (a default `m(x = super.k)`)
  and BODY. `super(...)` stays a SyntaxError there (not a derived constructor).
- Parser: `in_method` is now set (a) centrally in `parseMethodBody` (covers all method bodies), and
  (b) before `parseParams` in each object-method site (so a `super`-bearing default param parses).
- Runtime: `evalObjectLiteral` sets `home_object` on the function object for an object-literal
  method (gated on the AST `function` node's `is_method`) and for every accessor (always a method).
  `super.x` resolves against `home_object.[[Prototype]]` (`getSuperProperty`, unchanged).
- Supporting fix: `callFunction` now installs `this` / [[HomeObject]] / [[NewTarget]] BEFORE the
  parameter-initialization loop (§10.2.11 order), so `super.k` / `this.q` / `new.target` in a default
  parameter sees the correct method context (previously evaluated against the caller's context).

### 3. NewTarget meta-property (§13.3.12)
- `new` `.` `target` parses as a `new_target` MetaProperty node. After the `.`, the IdentifierName
  must be exactly `target` (no escapes), else a SyntaxError.
- §13.3.12.1 Early Error: `new.target` is a SyntaxError OUTSIDE a function body (e.g. at Script top
  level). Gated on a new parser flag `in_function` (true in any non-arrow function body, method,
  accessor, static block, and field initializer; arrows inherit it lexically, like `this`).
- §13.4.1.1 Early Error: NewTarget has AssignmentTargetType `invalid` — `++new.target`,
  `new.target++`, `new.target = x`, `new.target += x` are all SyntaxErrors (update/assignment-target
  refinement rejects the `new_target` node).
- Runtime: a new interpreter field `new_target` holds the active [[NewTarget]], saved/restored around
  each `[[Call]]` alongside `this_val`/`home_object`. `construct` sets it (to the constructor) via a
  one-shot `pending_new_target` hand-off that `callFunction` consumes (avoiding a parameter through
  39 call sites); an ordinary `[[Call]]` gets `undefined`; an arrow inherits it lexically.
  `new.target` propagates DOWN a `super(...)` chain unchanged (the parent ctor sees the derived
  class's target), handled in `runParentCtor` and the default-derived-ctor path.

## Out of scope
- `new.target` via `Reflect.construct(target, args, newTarget)` / `Reflect.apply` / tagged templates
  (depend on a caller-supplied newTarget; the `value-via-reflect-*` / `value-via-tagged-template`
  tests remain failing) — not part of this bounded slice.
- The hashbang `function-constructor.js` test (a hashbang inside a `Function()` constructor body).
- The `statements/try` parse gap is NOT a single bounded cause (catch BindingPattern params, etc.) —
  left untouched per the milestone's opportunistic clause.

## Conformance
- Full `language/`: passed 37292 → **37407** (85.4% → **85.7%**), **0 regressions** vs baseline.
- Per-feature: `comments/hashbang` 94.1%, `expressions/new.target` 78.6%, object-method `super`
  failures cleared in `expressions/object` / `computed-property-names/object`.
