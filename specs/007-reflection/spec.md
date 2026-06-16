# Feature Specification: M6 — Reflection / Property-Descriptor Built-ins

**Feature Branch**: `007-reflection`

**Created**: 2026-06-16

**Status**: Draft

**Input**: "M6: reflection / property-descriptor built-ins. Unblock `harness/propertyHelper.js` (used by a
huge number of positive tests, including many `class/*` tests already vendored in
`language/expressions`) by implementing property descriptors + the `Object.*` reflection API. M5 cleared
the *parse* prerequisite (`for (x in obj)`); propertyHelper.js now reaches its module body and throws a
*runtime* error because the engine lacks `Object.defineProperty`,
`Object.getOwnPropertyDescriptor/Names`, `Object.prototype.hasOwnProperty/propertyIsEnumerable`, and
`Function.prototype.call.bind`."

## Why (data-driven)
At M5 close, the dominant *structural* drag on conformance is the **harness-runtime gap**:
`vendor/test262/harness/propertyHelper.js` — the file behind `verifyProperty`, which a large fraction of
positive Test262 tests `$INCLUDE` — now PARSES (M5 fixed the `for (… in …)` parse error) but throws a
runtime `ReferenceError`/`TypeError` at its module top: lines 31–34 use `Function.prototype.call.bind`,
`Object.defineProperty`, `Object.getOwnPropertyDescriptor`, `Object.getOwnPropertyNames`,
`Object.prototype.hasOwnProperty`, and `Object.prototype.propertyIsEnumerable` — none of which the
engine implements. Any test whose prelude `$INCLUDE`s propertyHelper.js therefore dies before its own
body runs, in **both** modes. M6 implements the §6.1.7.1 Property-Descriptor model + the §10.1 ordinary
`[[DefineOwnProperty]]`/`[[GetOwnProperty]]` internal methods + the §20.1.2/§20.1.3 `Object` reflection
API that propertyHelper.js needs, plus `Function.prototype.call`/`apply`/`bind` (§20.2.3). The continuity
gate (`language/expressions`, harness metric, baseline passed **6077 / 35.8%**) MUST NOT regress (≥ 6077);
because the descriptor model changes how every object property behaves engine-wide (enumerability now
gates for-in / spread / `Object.keys`), regression risk is real and the before/after `mode+path` diff is
mandatory. Net gain is expected once Cycle 1 + Cycle 2 together fully unblock propertyHelper.js (the
`class/*` `verifyProperty` positives recover).

## User Scenarios & Testing *(mandatory)*
Users: engine devs / CI. Each cycle adds a coherent slice of the descriptor model + reflection API,
re-measures `language/expressions` conformance (the continuity gate — must not regress), runs the
mandatory before/after regression hunt by `mode+path` (the descriptor/enumerability change touches every
object → true regressions must be 0 or far outweighed by recoveries), reports whether propertyHelper.js
gets further (parse → module-top → `verifyProperty` callable), and stays bench-green (ljs ≤ Node; the
property-attribute change touches the object hot path — the data-property fast read/write MUST NOT regress
> 15%).

### US1 — Every own property carries attributes (§6.1.7.1) (P1)
Every own property records `[[Enumerable]]`, `[[Configurable]]`, and (data properties) `[[Writable]]`.
Ordinary creation — assignment, object-literal, class field, array element — defaults all three to
**true**. Built-in prototype methods (`Object.prototype.toString`, `Array.prototype.push`, …) are
**non-enumerable** so they never surface in `for (k in {})` / `Object.keys` / spread. The ordinary
`obj.x` data get/set stays a single-branch fast path (attributes stored alongside the value, not branched
on for plain reads).
**Test**: `for (var k in {a:1}) …` yields only `"a"` (no proto methods); `Object.keys`-style enumeration
skips a non-enumerable own property; a plain assignment `o.x = 5` creates an enumerable, writable,
configurable property (round-trips through `getOwnPropertyDescriptor`).

### US2 — `Object.defineProperty` / `getOwnPropertyDescriptor` / `getOwnPropertyNames` / `defineProperties` (§20.1.2) (P1)
`Object.defineProperty(O, P, Attrs)` (§20.1.2.4): ToPropertyDescriptor(Attrs) → ordinary
`[[DefineOwnProperty]]`. A NEW property defaults omitted attributes to **false** (vs **true** for
ordinary assignment). Supports data descriptors (`value`/`writable`) and accessor descriptors
(`get`/`set`) + `enumerable`/`configurable`. Redefining a non-configurable property incompatibly throws
TypeError (basic check). `Object.getOwnPropertyDescriptor(O, P)` (§20.1.2.8) returns a fresh descriptor
object (`{value,writable,enumerable,configurable}` for data, `{get,set,enumerable,configurable}` for
accessor) or `undefined` if absent. `Object.getOwnPropertyNames(O)` (§20.1.2.10) returns ALL own string
keys (enumerable or not; for arrays the indices + `"length"`). `Object.defineProperties(O, Props)`
(§20.1.2.5) applies each own enumerable descriptor of `Props`.
**Test**: `Object.defineProperty(o,'x',{value:5,enumerable:false}); o.x` → `5`, and `o.x` is skipped by
for-in/keys; `Object.getOwnPropertyDescriptor(o,'x').value` → `5`, `.enumerable` → `false`,
`.writable`/`.configurable` → `false` (omitted defaults); a getter via `defineProperty` is invoked on
read; `Object.getOwnPropertyNames` includes the non-enumerable name; redefining a non-configurable prop
throws.

### US3 — `Object.prototype` reflection: `hasOwnProperty` / `propertyIsEnumerable` / `isPrototypeOf` (§20.1.3) (P1)
`Object.prototype.hasOwnProperty(V)` (§20.1.3.2): true iff `ToObject(this)` has an OWN property with key
`ToPropertyKey(V)` (own only — inherited → false). `Object.prototype.propertyIsEnumerable(V)` (§20.1.3.4):
true iff that own property exists AND is enumerable. `Object.prototype.isPrototypeOf(V)` (§20.1.3.3):
true iff `this` appears anywhere on `V`'s prototype chain. These three are themselves **non-enumerable**
methods on `Object.prototype`.
**Test**: `({a:1}).hasOwnProperty('a')` → true; `({}).hasOwnProperty('toString')` → false (inherited);
`Object.defineProperty(o,'x',{enumerable:false}); o.propertyIsEnumerable('x')` → false; an array
`[1].hasOwnProperty(0)` → true / `[1].hasOwnProperty('length')` → true; `proto.isPrototypeOf(child)`.

### US4 — Enumerable-awareness across for-in / spread / keys (P1)
for-in (M5), object spread `{...o}` (§7.3.25 CopyDataProperties), and any keys enumeration visit only
ENUMERABLE own string keys (for-in additionally walks inherited enumerable keys). Built-in prototype
methods being non-enumerable is what makes `for (k in [])` / `for (k in {})` correctly empty and keeps
`{...o}` from copying inherited proto methods.
**Test**: `for (k in {a:1})` yields only `"a"`; `{...{a:1}}` has only `a`; defining a non-enumerable own
prop then spreading omits it.

### US5 — `Function.prototype.call` / `apply` / `bind` (§20.2.3) (Cycle 2) (P1)
`Function.prototype.call(thisArg, ...args)` (§20.2.3.3) and `.apply(thisArg, argArray)` (§20.2.3.1)
invoke `this` (a callable) with the given receiver + args. `.bind(thisArg, ...bound)` (§20.2.3.2) returns
a new function that prepends the bound args and fixes the receiver. propertyHelper.js's
`Function.prototype.call.bind(Object.prototype.hasOwnProperty)` idiom (line 31) needs all three.
**Test**: `function f(a){return this.x+a} f.call({x:1},2)` → `3`; `.apply({x:1},[2])` → `3`;
`var g=f.bind({x:10}); g(5)` → `15`; the `call.bind(hasOwnProperty)` idiom yields a working predicate.

### Edge Cases
- `Object.defineProperty` of an EXISTING property updates only the stated fields, preserving the others
  (not resetting omitted attributes to false) — only a NEW property defaults omitted to false.
- A non-configurable property: changing `value` (when non-writable), `enumerable`, `configurable`, or
  data↔accessor conversion → TypeError; an idempotent redefine (same values) is allowed.
- `getOwnPropertyDescriptor` of an Array index returns `{value, writable:true, enumerable:true,
  configurable:true}`; of `"length"` returns `{value, writable:true, enumerable:false, configurable:false}`.
- `hasOwnProperty`/`propertyIsEnumerable`/`isPrototypeOf` on a primitive `this` ToObject-box (M-subset:
  string boxing for the index/length keys; number/boolean → no own keys).
- A built-in prototype method must be non-enumerable so `Object.keys(Object.prototype)`-style and for-in
  don't surface it — this is load-bearing for the propertyHelper.js unblock.

## Requirements *(mandatory)*
- **FR-001** (US1): Extend each own property's stored shape (`src/object.zig` `PropertyValue`) to carry
  `[[Writable]]` (data only), `[[Enumerable]]`, `[[Configurable]]` alongside the data/accessor payload.
  The hot `get`/`set` data path stays single-branch (no per-read attribute branch). Ordinary
  assignment / object-literal / class-field / array-element creation defaults all attributes to **true**.
- **FR-002** (US1): Built-in prototype methods installed in `src/builtins.zig` (and seeded native protos)
  are **non-enumerable** (and the spec's writable/configurable: methods writable+configurable,
  non-enumerable). The data-define API used by builtins must let a caller specify attributes.
- **FR-003** (US2): `Object.defineProperty(O,P,Attrs)` — ToPropertyDescriptor(Attrs) → §10.1.6
  OrdinaryDefineOwnProperty: a NEW property defaults omitted attributes to **false**; an EXISTING
  property keeps unstated fields. Data vs accessor descriptors; basic non-configurable TypeError.
- **FR-004** (US2): `Object.getOwnPropertyDescriptor(O,P)` → fresh descriptor object or `undefined`;
  `Object.getOwnPropertyNames(O)` → array of all own string keys (incl. non-enumerable; arrays:
  indices + `"length"`); `Object.defineProperties(O,Props)`.
- **FR-005** (US3): `Object.prototype.hasOwnProperty(V)` / `propertyIsEnumerable(V)` / `isPrototypeOf(V)`,
  all three non-enumerable on `Object.prototype`.
- **FR-006** (US4): for-in, object spread, and keys enumeration honor `[[Enumerable]]` (visit only
  enumerable own string keys; for-in also inherited enumerable). Replaces M5's "stop-at-builtin-proto"
  heuristic with a true per-property enumerability check (the heuristic stays as a cheap short-circuit
  but correctness now comes from the flag).
- **FR-007** (US5, Cycle 2): `Function.prototype.call`/`apply`/`bind` (§20.2.3), non-enumerable on
  `Function.prototype`; a real `Function.prototype` object reachable as a global `Function` ctor's proto.
- **FR-008**: Spec-clause citations on every new internal method / abstract operation (Principle III):
  §6.1.7.1 Property Attributes, §10.1.6 OrdinaryDefineOwnProperty, §10.1.5 OrdinaryGetOwnProperty,
  §6.2.6 ToPropertyDescriptor / FromPropertyDescriptor, §20.1.2.*/§20.1.3.*, §20.2.3.*.
- **FR-009**: ljs ≤ Node on the bench (absolute pre-commit gate); the property-attribute change touches
  the object hot path — the data-property fast read/write MUST NOT regress > 15% (optimize the fast path,
  never the baseline).
- **FR-010**: The descriptor/enumerability change must NOT net-regress the continuity gate
  (`language/expressions`, harness metric): true regressions by `mode+path` must be 0 or far outweighed.

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `passed` (harness metric) ≥ the M5-close baseline of 6077 (35.8%).
  [Cycle 1 result: **6139 (+62), 36.2%** — 0 true regressions / 62 recoveries by `mode+path`; baseline
  bumped to 6139.]
- **SC-002**: propertyHelper.js gets further: after Cycle 1 its module-top no longer dies on
  `Object.defineProperty`/`getOwnPropertyDescriptor`/`getOwnPropertyNames`/`hasOwnProperty`/
  `propertyIsEnumerable` [verified — all are `typeof === "function"` now]; the LAST remaining blocker is
  line 31 `Function.prototype.call.bind`. After Cycle 2 (`Function.prototype.call`/`apply`/`bind`) the
  file loads and `verifyProperty` is callable — the `class/*` `verifyProperty` positives recover. [Cycle 1
  already recovered the +62 tests that use these APIs directly, not via `verifyProperty`.]
- **SC-003**: ≥8 reflection unit tests pass (`zig build test` exit 0): `defineProperty` data (value/
  enumerable:false → readable but skipped by for-in); `getOwnPropertyDescriptor` (value + attribute
  flags, omitted → false); a getter via `defineProperty`; `getOwnPropertyNames` includes a non-enumerable
  name; `hasOwnProperty` own-true / inherited-false; `propertyIsEnumerable`; `isPrototypeOf`;
  `for (k in {a:1})` yields only `"a"`.
- **SC-004**: M0–M5 tests still green; bench green (ljs ≤ Node, no data-prop fast-path regression); no
  leaks under the testing allocator; no net regression on the `mode+path` diff (FR-010).

## Assumptions
- Tree-walk tier retained; this is object-model + built-ins work. The descriptor model stores 3 bools per
  property (a small struct beside the value); the hot read path switches on data/accessor exactly as
  today (no new branch). `Object.preventExtensions`/`seal`/`freeze` extensibility enforcement,
  `[[Set]]` non-writable rejection in strict mode, full §10.1.6.3 ValidateAndApplyPropertyDescriptor
  invariants, and Symbol/integer-key ordering are M-subset-simplified: Cycle 1 implements the common
  data/accessor define + a basic non-configurable guard; the full invariant matrix is deferred unless a
  test demands it.
- Enumeration order: own string keys in `StringHashMapUnmanaged` iteration order (Array indices in
  numeric order first); strict §10.1.11.1 OrdinaryOwnPropertyKeys ordering (integer keys ascending then
  insertion order) is NOT guaranteed for non-array string keys unless tests require it.
- `ToPropertyKey` is ToString in the M-subset (no Symbol keys yet). `ToObject` boxing for the
  `Object.prototype` reflection methods on primitives is String-only (number/boolean → no own keys).

## Dependencies
- M1 engine (objects, functions, Completion records, environment scoping), M2 arrays/strings, M3 parser/
  spread, M4 object model (accessors, classes, private names), M5 for-in/for-of (the parse + enumeration
  scaffold this milestone makes enumerability-aware). Test262 harness; bench gate. ECMA-262 §6.1.7.1,
  §6.2.6, §10.1.5/§10.1.6, §20.1.2/§20.1.3, §20.2.3.
