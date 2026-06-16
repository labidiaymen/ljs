# M22 — Number & Boolean constructors (§21.1 / §20.3)

**Status:** DONE — `language/` 63.2% → 64.0% (+357, 0 regressions). 650 failing files referenced
`Number`/`Boolean`; both were unimplemented.

## What
- `Number(x)` — ToNumber (`Number()` → 0); `Boolean(x)` — ToBoolean. Callable conversion (the
  high-frequency form). `Number.prototype`/`Boolean.prototype` inherit `%Object.prototype%` and carry
  `.constructor` (back-ref) + `toString`/`valueOf` (operating on a primitive `this`).
- §21.1.2 Number value properties: `MAX_SAFE_INTEGER`, `MIN_SAFE_INTEGER`, `MAX_VALUE`, `MIN_VALUE`,
  `POSITIVE_INFINITY`, `NEGATIVE_INFINITY`, `NaN`, `EPSILON` (non-writable/enumerable/configurable).
- §21.1.2 static predicates `Number.isNaN`/`isFinite`/`isInteger`/`isSafeInteger` (no coercion).

## Deferred
- Wrapper objects: `new Number(x)` / `new Boolean(x)` make a plain object (no `[[NumberData]]`/
  `[[BooleanData]]` internal slot — same M-subset deviation as `new String`). Primitive-`this`
  prototype methods work; wrapper-`this` throws.
- Number/Boolean boxing in property access (`(5).toString()` doesn't resolve `Number.prototype`).
- `Number.parseInt`/`parseFloat` (and the global `parseInt`/`parseFloat`).
