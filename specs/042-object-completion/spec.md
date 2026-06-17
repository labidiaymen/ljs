# M42 — Object built-in completion (§20.1)

## Goal
Close the largest systematic gaps in `built-ins/Object` (~63% at HEAD). Scope is 100%
ECMAScript; no host APIs. Two systematic causes dominate the failing set:

1. **`Object.prototype.toString` is tag-blind** (§20.1.3.6) — it always returns
   `"[object Object]"`. Hundreds of tests use `Object.prototype.toString.call(x)` as a
   brand check and as the `@@toStringTag` probe.
2. **Missing static methods** — `Object.fromEntries`, `Object.hasOwn`,
   `Object.getOwnPropertySymbols`, `Object.groupBy`.
3. **Missing `__proto__` accessor** on `%Object.prototype%` (Annex B.2.2.1) — distinct
   from the object-literal `__proto__:` form (already done).

## Part A — §20.1.3.6 Object.prototype.toString ( ) — the brand/tag algorithm
1. If `this` is `undefined` → `"[object Undefined]"`.
2. If `this` is `null` → `"[object Null]"`.
3. `O = ToObject(this)` (primitives box; our engine reads the brand off the boxed kind).
4. `builtinTag` by the spec's ordered internal-slot probe:
   - IsArray(O) → `"Array"`            (engine: `kind == .array`)
   - O has `[[ParameterMap]]` → `"Arguments"` (engine: `is_arguments` marker)
   - O has `[[Call]]` → `"Function"`   (engine: `kind == .function`, incl. native/bound)
   - O has `[[ErrorData]]` → `"Error"` (engine: `error_data` marker)
   - O has `[[BooleanData]]` → `"Boolean"` (engine: `primitive == .boolean`)
   - O has `[[NumberData]]` → `"Number"` (engine: `primitive == .number`)
   - O has `[[StringData]]` → `"String"` (engine: `primitive == .string`)
   - (Date / RegExp not yet in the engine — fall through)
   - else → `"Object"`.
5. `tag = Get(O, @@toStringTag)`. If `tag` is **not a String**, set `tag = builtinTag`.
   (A `@@toStringTag` getter is honoured via the ordinary [[Get]]; a non-string value is
   ignored.)
6. Return `"[object " + tag + "]"`.

Receiver coercion: a primitive `this` (number/string/boolean/symbol/bigint) is a wrapper
brand only when boxed; called directly on a primitive via `.call(5)` the spec ToObject's
it → the matching wrapper tag (`Number`/`String`/`Boolean`); symbol/bigint → `"Object"`.

Engine markers added to `Object` (object.zig):
- `error_data: bool` — set true when an Error/AggregateError/SuppressedError instance is
  created (the three `*_error_ctor` construct paths AND `throwError`). Mirrors `[[ErrorData]]`.
- `is_arguments: bool` — set true by `makeArgumentsObject`. Mirrors `[[ParameterMap]]`'s
  presence for the tag probe (the M-subset arguments object is otherwise ordinary).

## Part B — new static methods
- **`Object.fromEntries(iterable)`** (§20.1.2.7): create a fresh ordinary object
  proto-linked to %Object.prototype%; iterate `iterable` via the @@iterator protocol; each
  entry must be an Object; read `entry[0]` (key, ToPropertyKey) and `entry[1]` (value);
  CreateDataPropertyOnObject (an own enumerable, writable, configurable data property).
- **`Object.hasOwn(O, P)`** (§20.1.2.13): `O = ToObject(O)`; `key = ToPropertyKey(P)`;
  return HasOwnProperty(O, key) — own string OR symbol key, regardless of enumerability.
- **`Object.getOwnPropertySymbols(O)`** (§20.1.2.10): `O = ToObject(O)`; return a fresh
  Array of the object's own **Symbol** keys, in insertion order (the `symbol_props` store).
- **`Object.groupBy(items, callback)`** (§20.1.3 / §7.3.35 GroupBy with COLLECTION=property):
  callback must be callable; iterate `items`; `key = ToPropertyKey(callback(item, index))`;
  group items into arrays keyed by `key`; return an object with **null prototype** whose
  own enumerable properties are the group arrays (insertion order of first-seen key).

## Part C — `__proto__` accessor (Annex B.2.2.1)
Install a configurable, **non-enumerable accessor** named `__proto__` on %Object.prototype%:
- **get** (§B.2.2.1.1): `O = ToObject(this)`; return `O.[[GetPrototypeOf]]()`. For a
  primitive `this`, boxes then returns the wrapper proto's prototype (e.g. on a string →
  String.prototype).
- **set** (§B.2.2.1.2): `O = RequireObjectCoercible(this)`; if the value is neither Object
  nor null → return undefined (no-op, NOT a throw); if `this` is not an Object → no-op;
  else `O.[[SetPrototypeOf]](value)` (may throw TypeError on a non-extensible object whose
  proto would change, or on a cycle). Returns undefined.

Two new native ids: `object_proto_getter` / `object_proto_setter`. Because this is an
accessor on %Object.prototype% (which most objects inherit), the `getProperty`/`setProperty`
fast path must continue to special-case neither — the accessor is found through the ordinary
prototype walk; the get/set natives route through the existing set/getPrototypeOf ops.

## Non-goals
- Date / RegExp brands (no such exotics yet) — they correctly fall through to `"Object"`.
- The full §10.1.6.3 ValidateAndApplyPropertyDescriptor invariant matrix — out of scope;
  only fix high-frequency descriptor cases if they surface, no chasing.

## Conformance intent
`built-ins/Object` passed-count strictly increases with **0 within-Object regressions**;
`language/` reports **no regression** against `baseline/language.json` (a `@@toStringTag`-aware
toString and an inherited `__proto__` accessor both touch language-level paths).
