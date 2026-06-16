# M27 — Class runtime semantics

## Context
`statements/class` (~1801) + `expressions/class` (~1522) fail mostly at RUNTIME
(`unexpected_error`), not parse. Classes are largely implemented; the failures are
semantic edge cases. This milestone diagnoses the class runtime failures, finds the
highest-impact systematic cause(s), and fixes them with 0 regressions vs
`baseline/language.json`.

## Diagnosis (HEAD 4f17cd2, language passed=31239, 71.5%)
1558 unique `class/*` tests fail with `unexpected_error`. Histogram by sub-feature:
- `dstr` 984 — destructuring in class method/ctor parameters (DOMINANT)
- `elements` 274, `subclass` 80, `subclass-builtins` 44, `definition` 22, …

Within `dstr`, grouped by destructuring CASE (each case appears ~48× across the
method/static/private/gen/async cross-product):
- `*-id-init-fn-name-{fn,gen,cover,class,arrow}` and `obj-ptrn-id-init-fn-name-*`
  (6 cases × 48 ≈ **288 tests**) — a destructuring default initializer that is an
  **anonymous function/class** must take the **binding identifier** as its `name`
  (§8.6.2 SingleNameBinding step 6.d / §13.15.5.2 / §15.1.3 IteratorBindingInitialization).
  Reproduced minimally and confirmed broken in EVERY binding context, not just classes:
  - `function f({fn = function(){}}){}` → `fn.name` was `""` (expected `"fn"`)
  - `function f(cb = function(){}){}`   → `cb.name` was `""` (expected `"cb"`)
  - `var {gn = function(){}} = {}` / `var [an = function(){}] = []` — both `""`.
- `obj-ptrn-rest-skip-non-enumerable` (48), `ary-ptrn-elem-id-iter-val-array-prototype`
  (48), and a long tail of `*-err`/`*-throws`/`*-undef`/`*-null` edge cases (16 each) —
  separate, smaller causes; the array-prototype/iter cases revolve around iterator
  semantics already largely handled by `destrOpen`/`destrStep`.

## Root cause #1 (FIXED) — missing NamedEvaluation on destructuring/param defaults
When a binding/assignment target is a single identifier and its `= Initializer`
default is applied (matched value was `undefined`), the engine evaluated the default
but never performed §8.4 NamedEvaluation, so anonymous function/class initializers
stayed unnamed (`name === ""`).

The default was applied at FOUR independent sites with no naming:
- ordinary call param defaults (`callFunction`, identifier fast-path),
- generator-body param defaults (`runGeneratorBody`),
- array binding-pattern element defaults (`bindPattern` `.array`),
- object binding-pattern property defaults (`bindPattern` `.object`),
- assignment-pattern identifier target with default (`assignElement` `.assign`).

### Fix
Apply `maybeSetAnonName(initializerNode, value, identifierName)` immediately after a
default is used, but ONLY when:
- the matched value was `undefined` (the default was actually taken), AND
- the binding target is a single identifier (binding `.identifier` / assignment
  `.assign`), AND
- the initializer node is an anonymous function/class literal (handled by the existing
  `maybeSetAnonName`, which is a no-op otherwise).

This mirrors the existing NamedEvaluation already done for `let f = <anon>`,
`f = <anon>`, object-literal `{f: <anon>}`, and class fields.

## Out of scope / deferred
The remaining `dstr` edge cases (`*-err`, `*-undef`, `*-null`, `rest-skip-non-enumerable`,
`iter-val-array-prototype`) and the non-`dstr` buckets (`elements`, `subclass`) are
distinct causes left for a later milestone unless they fall out of the same fix.

## Gates
`zig build` / `zig build test` / `zig build lint` (0/0); full `language/` run with
`passed ≥ 31239` and "no regression vs baseline"; `zig build bench` "perf: ok" and
ljs ≤ Node.
