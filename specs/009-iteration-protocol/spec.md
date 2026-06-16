# Feature Specification: M8 — Iterator Protocol + Symbol

**Feature Branch**: `009-iteration-protocol`

**Created**: 2026-06-16

**Status**: Cycle 1 done

**Input**: "M8: the iterator protocol + Symbol. M7 close noted the dominant remaining `assignment/dstr` +
`object/dstr` failures (and a large slice of `for-of` / spread) need a *real* §7.4 iteration protocol —
array assignment patterns / for-of / spread were pulling positionally from a hard-coded Arrays+Strings
model instead of calling `Symbol.iterator`. The protocol can't exist without the `symbol` primitive and
the well-known `Symbol.iterator` key, so M8 lands a minimal §20.4 Symbol (the `symbol` Value variant +
`Symbol()` + the well-known symbols) and the full §7.4 GetIterator / IteratorStep / IteratorClose /
IterateToList operations, then re-wires for-of, spread, and array destructuring onto them (with
IteratorClose on break/return/throw)."

## Why (data-driven)

At M7 close the continuity gate (`language/expressions`, harness metric) is **6,718 / 39.6%**. M3–M7 ran
for-of, spread, and array destructuring on a **hard-coded iterable model** (`iterableToSlice`: Arrays +
Strings only) — correct for those two types but not the spec's §7.4 protocol, so any test that observes
the iterator (a custom `[Symbol.iterator]`, a `.next()` call count, iterator-close on abrupt completion,
or a non-array iterable) fails. Those failures cluster across `language/expressions` (spread, `for`/`of`),
`language/statements/for-of`, and the iterator-shaped remainder of `assignment/dstr` / `object/dstr`
flagged at M7 close.

The protocol is gated on two missing primitives: there is no `symbol` Value (so `typeof x === "symbol"`,
symbol identity, and symbol-keyed property access all fail) and no `Symbol.iterator` well-known key (so a
user iterable cannot even be *recognized*). M8 therefore lands a **minimal** §20.4 Symbol first — the
`symbol` primitive + `Symbol()` constructor + the four well-known symbols this milestone needs — then the
§7.4 operations on top, then re-wires the three consumers. The full Symbol surface (registry
`Symbol.for`/`keyFor`, all well-known symbols, `Symbol.prototype` methods) and generators/`yield` (the big
remaining lever that *produces* iterators) are deferred to later cycles.

The change touches the Value union (a new variant → every exhaustive `switch (value)` site), the Object
model (a symbol-keyed property store), and the hot string property get/set path (which MUST stay
untouched), so the regression risk is engine-wide and the before/after `mode+path` diff is mandatory.

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Each cycle adds a coherent slice of §20.4 / §7.4, re-measures
`language/expressions` (the continuity gate — must not regress), runs the mandatory before/after
regression hunt by `mode+path` (the new Value variant + symbol-keyed store touch every value switch and
the property model → true regressions must be 0 or far outweighed by recoveries), and stays bench-green
(the symbol store is a separate map; the string get/set hot path and the for-of/spread loop are unchanged
for Arrays/Strings — the native iterator fast-path avoids a `.next()` call per element only where a user
`[Symbol.iterator]` is absent).

### US1 — The `symbol` primitive (§20.4, §6.1.5) (P1)
A new sixth primitive. `typeof Symbol() === "symbol"`. Each `Symbol()` call is a unique value with
**identity equality** (`Symbol() !== Symbol()`, `s === s`); `===`/`!==`/`SameValue` compare identity. A
symbol carries an optional **description** (`Symbol("d").description === "d"`, `Symbol().description ===
undefined`). A symbol is **not** implicitly coerced to string: it throws a TypeError in a template literal
and in `+`/string concatenation, but is allowed via `String(sym)` and `sym.toString()` (→ `"Symbol(d)"`).
**Test**: `typeof Symbol() === "symbol"`; `Symbol() !== Symbol()`; `var s = Symbol(); s === s`;
`Symbol("d").description === "d"`; `Symbol().description === undefined`; `String(Symbol("d")) ===
"Symbol(d)"`; `Symbol("d").toString() === "Symbol(d)"`; `` `${Symbol()}` `` throws TypeError;
`"" + Symbol()` throws TypeError.

### US2 — `Symbol()` constructor + well-known symbols (§20.4.1, §20.4.2) (P1)
`Symbol` is a callable (not a constructor): `Symbol()` / `Symbol("d")` returns a symbol; `new Symbol()`
throws a TypeError (§20.4.1 "Symbol is not intended to be used with `new`"). The well-known symbols this
milestone needs are exposed as data properties of `Symbol`: `Symbol.iterator`, `Symbol.asyncIterator`,
`Symbol.toStringTag`, `Symbol.hasInstance` — each a unique frozen symbol shared across the realm.
**Test**: `typeof Symbol === "function"`; `Symbol() ` returns a symbol; `new Symbol()` throws TypeError;
`typeof Symbol.iterator === "symbol"`; `Symbol.iterator === Symbol.iterator` (stable); the four well-known
symbols are pairwise distinct.

### US3 — Symbol-keyed properties (§6.1.7, §7.1.* property keys) (P1)
An object property key may be a symbol. `obj[sym] = v` / `obj[sym]` store and read on a **separate
symbol-keyed store** on the Object (so the string-keyed hot path is untouched). Symbol-keyed properties
are **not enumerated** by `for-in`, `Object.keys`, `JSON`, spread, or string-key iteration; they require
the explicit symbol key to access. Setting `obj[Symbol.iterator]` makes `obj` a user iterable (US5).
**Test**: `var s = Symbol(); var o = {}; o[s] = 1; o[s] === 1`; `Object.keys(o).length === 0`;
`for (var k in o) {}` visits nothing; two distinct symbols are independent keys on the same object;
a computed-key object literal `{[s]: 1}` stores under the symbol.

### US4 — §7.4 iteration protocol operations (§7.4.2–.4.8) (P1)
`GetIterator(obj)` calls `obj[Symbol.iterator]()` and requires the result to be an Object (else
TypeError); `IteratorNext`/`IteratorStep` call `.next()` and read `done`/`value` (a non-object result
throws); `IteratorClose(iterator, completion)` calls `.return()` if present when the consumer finishes
early (break / return / throw) and **preserves** the original completion (a throw in the body wins over a
`.return()` error per §7.4.8); `IterateToList`/`IteratorToList` drives an iterator to exhaustion into a
slice. Array.prototype / String.prototype provide **native** iterators so the common case does not pay a
`.next()` dispatch per element.
**Test**: a hand-rolled iterable `{ [Symbol.iterator]() { return { i:0, next() { return this.i < 3 ?
{value:this.i++,done:false} : {value:undefined,done:true}; } }; } }` drives a for-of to `0,1,2`; a
`.next()` returning a non-object throws; `.return()` is called exactly once on an early break.

### US5 — Wiring for-of / spread / array destructuring onto §7.4 (§14.7.5, §13.2.4, §13.15.5) (P1)
`for-of`, array spread (`[...x]`, `f(...x)`), and array destructuring (`[a,b] = x`, `var [a,b] = x`,
`function f([a,b]){}`) now consume the iterator protocol: they `GetIterator`, loop on `IteratorStep`, and
**IteratorClose** on any abrupt completion (a `break` / `return` / `throw` inside a for-of body, a
destructuring target that throws, an early-finished pattern). A user object with `[Symbol.iterator]` is now
iterable everywhere; Arrays / Strings keep a native iterator fast-path.
**Test**: `for (const x of userIterable) ...` works; `[...userIterable]` spreads; `var [a,b] =
userIterable`; `break` inside `for (x of it)` calls `it.return()`; a throw inside the body still calls
`.return()` and rethrows the body's error (not the return's).

### US6 — Native iterators on Array / String (§23.1.5, §22.1.3.* / §6.1.4) (P1)
`Array.prototype[Symbol.iterator]` (=== `Array.prototype.values`) and `String.prototype[Symbol.iterator]`
return native iterator objects (an ArrayIterator over indices, a StringIterator over code points). These
satisfy `GetIterator` for the built-ins and let `[...arr]` / `for (const c of str)` route through the same
§7.4 path as user iterables.
**Test**: `typeof [][Symbol.iterator] === "function"`; `[][Symbol.iterator] === [].values`;
`[...("ab")]` → `["a","b"]`; `[...[1,2,3]]` → `[1,2,3]`; `for (const c of "hi") ...` → `"h","i"`.

### Edge Cases
- A symbol used where a string is required for property access is coerced by **ToPropertyKey** (kept as a
  symbol, not stringified) — `obj[sym]` is a symbol key, `obj[String(sym)]` is a *string* key, and the two
  are different properties.
- IteratorClose must **swallow nothing**: if the body completion is a throw, a `.return()` that also throws
  is discarded and the original throw propagates (§7.4.8 step 6).
- A for-of over an Array/String uses the native iterator but is still observable as the protocol (a test
  that overrides `Array.prototype[Symbol.iterator]` sees its override called) — the fast-path only applies
  when the well-known method is the unmodified native one.
- Symbol → string is a TypeError only for **implicit** coercion (template, `+`); `String(sym)` /
  `sym.toString()` / `` `${String(sym)}` `` are allowed.
- `new Symbol()` is a TypeError (callable-not-constructor), distinct from `Symbol()` returning a value.

## Requirements *(mandatory)*
- **FR-001** (US1): A new `symbol` variant on the `Value` union (`src/value.zig`) — an opaque identity
  (unique id) + optional description string. `typeof` → `"symbol"`; `===`/`SameValue` compare identity;
  every exhaustive value `switch` (printing, `typeof`, equality, ToPrimitive, ToString, ToNumber) handles
  it (ToString/ToNumber/implicit-ToPrimitive throw TypeError; `String(sym)` / `.toString()` allowed).
- **FR-002** (US2): A `Symbol` callable in the global (`src/builtins.zig`) — `Symbol([description])`
  returns a fresh symbol; `[[Construct]]` (i.e. `new Symbol()`) throws TypeError. The four well-known
  symbols (`iterator`, `asyncIterator`, `toStringTag`, `hasInstance`) as stable realm-level data
  properties of `Symbol`.
- **FR-003** (US3): A **separate symbol-keyed property store** on `Object` (`src/object.zig`) —
  non-enumerated (invisible to for-in / `Object.keys` / spread / JSON), keyed by symbol identity. The
  string-keyed get/set **hot path is untouched** (the symbol store is consulted only when the key is a
  symbol). ToPropertyKey keeps a symbol key as a symbol.
- **FR-004** (US4): §7.4 operations (`src/abstract_ops.zig`) — `getIterator` / `iteratorNext` /
  `iteratorStep` / `iteratorClose` / `iterateToList`, spec-faithful (GetIterator requires an Object
  result; IteratorStep reads `done`/`value`; IteratorClose calls `.return()` and preserves the original
  completion per §7.4.8).
- **FR-005** (US5): Re-wire for-of (`src/interpreter.zig`), array spread, and array destructuring
  (`bindPattern` + `assignPattern`) onto §7.4 with **IteratorClose on break/return/throw**. A native
  iterator fast-path for unmodified Array/String avoids per-element `.next()` dispatch.
- **FR-006** (US6): Native `Array.prototype[Symbol.iterator]` (=== `.values`) + `String.prototype
  [Symbol.iterator]` (`src/builtins.zig`) returning native iterator objects.
- **FR-007**: Spec-clause citations on every new Value variant / Object field / abstract op / wiring site
  (§6.1.5 Symbol type, §20.4 Symbol objects, §6.1.7 property keys, §7.4 Operations on Iterator Objects,
  §14.7.5 for-of, §13.2.4 spread, §13.15.5 destructuring, §23.1.5/§22.1.3 native iterators).
- **FR-008**: ljs ≤ Node on the bench (absolute pre-commit gate); the symbol store is a separate map and
  the for-of/spread/destructuring fast-path keeps Arrays/Strings off the `.next()` dispatch — the
  ordinary loop / property hot path MUST NOT regress > 15%.
- **FR-009**: No net regression on the continuity gate (`language/expressions`, harness metric): true
  regressions by `mode+path` must be 0 or far outweighed by recoveries.

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `passed` (harness metric) ≥ the M7-close baseline of 6,718 (39.6%).
  [Cycle 1 result: **6,825 (+107), 40.2%** — 0 true regressions / 107 recoveries by `mode+path`; committed
  baseline bumped 6,718 → 6,825.]
- **SC-002**: A custom user iterable (`[Symbol.iterator]` returning a hand-rolled `.next()`) is consumable
  by for-of, spread, and array destructuring; `break`/`throw` inside a for-of calls `.return()` and
  preserves the body completion. The native Array/String iterators satisfy the same protocol.
- **SC-003**: Symbol unit tests pass (`zig build test` exit 0): `typeof`/identity/description; `Symbol()`
  vs `new Symbol()`; implicit-coercion TypeError vs `String()`/`.toString()`; symbol-keyed property
  store + non-enumeration; the well-known symbols; the §7.4 protocol (user iterable for-of, `.return()`
  on early break, non-object `.next()` throws); native Array/String iterators (`[...arr]`, `[...str]`).
- **SC-004**: M0–M7 tests still green; lint 0/0; bench green (ljs ≤ Node, no hot-path regression); no net
  regression on the `mode+path` diff (FR-009).

## Assumptions
- Tree-walk tier retained; this is a new Value variant + a symbol-keyed store + the §7.4 abstract ops +
  re-wiring three existing consumers. The iterator *producers* in scope are the native Array/String
  iterators and arbitrary user objects with `[Symbol.iterator]`; **generators/`yield`** (the language-level
  iterator producer, and the dominant remaining lever) are **deferred** to the next milestone.
- A **minimal** §20.4 Symbol: the `symbol` primitive, `Symbol()` (callable, no `new`), the four well-known
  symbols this milestone consumes (`iterator`/`asyncIterator`/`toStringTag`/`hasInstance`). The global
  **Symbol registry** (`Symbol.for` / `Symbol.keyFor`), the remaining well-known symbols
  (`toPrimitive`/`match`/`replace`/`species`/…), and the full `Symbol.prototype` surface are deferred.
- `Symbol.toStringTag` / `Symbol.hasInstance` are *exposed* (so tests that reference them resolve) but
  their behavioral hooks (`Object.prototype.toString` tag dispatch, `instanceof` `[Symbol.hasInstance]`
  dispatch) are a later cycle; this milestone wires only `Symbol.iterator`.
- `Map`/`Set` (the canonical iterable built-ins) and **async iteration** (`Symbol.asyncIterator`,
  `for-await-of`) are out of scope.

## Dependencies
- M2 Array/String built-ins (native iterator targets), M3 spread/rest + destructuring binding
  (`bindPattern`/`iterableToSlice`), M5 for-of statement, M6 property-attribute model + enumerability
  (the symbol store is non-enumerated alongside it), M7 destructuring assignment (`assignPattern`, the
  second array-pattern consumer re-wired onto §7.4). Test262 harness; bench gate. ECMA-262 §6.1.5,
  §6.1.7, §7.4, §13.2.4, §13.15.5, §14.7.5, §20.4, §22.1.3, §23.1.5.
