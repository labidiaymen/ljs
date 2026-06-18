# Spec 076 — Array sort SortCompare coercion fidelity

**Status:** Done (measured: built-ins/Array/prototype/sort 49 → 55 passing, +6 tests / +3 unique).

## Summary
`Array.prototype.sort` / `Array.prototype.toSorted` share one `SortCompare` helper
(`src/builtin_array.zig:compare`). It used the non-throwing shortcut coercions, which violates
ECMA-262 §23.1.3.30.1 in two ways:

1. **Default comparator (no `comparefn`)** must do `? ToString(x)` / `? ToString(y)` — the *full*
   ToString, which runs `ToPrimitive(string)` on an object element (its `toString`/`valueOf`) and
   throws a `TypeError` for a Symbol element. The shortcut `it.toString` instead returned the
   literal `"[object Object]"` for *every* object, so object elements were mis-ordered, and a
   Symbol element was silently stringified rather than throwing.
2. **User comparator** result must be `? ToNumber(v)` — the *throwing* ToNumber, so a comparator
   returning a Symbol/BigInt throws a `TypeError`. The shortcut `ops.toNumber` swallowed those.

## Governing clause
ECMA-262 §23.1.3.30.1 `SortCompare ( x, y )`:
- step 4: `let v be ? ToNumber(? Call(comparefn, undefined, « x, y »))` (throwing ToNumber).
- steps 5–7: `xString be ? ToString(x)`, `yString be ? ToString(y)`, then code-unit order
  (throwing ToString; objects coerce via ToPrimitive, Symbols throw).

## User scenarios (Given/When/Then)
- **Object elements, default compare.**
  Given `var obj = { toString(){ return -2 } }` and `[obj, "X"]`,
  When `.sort()`,
  Then `obj` (ToString `"-2"`) orders before `"X"` — i.e. `String(a[0]) === "-2"`.
  (Test262: `S15.4.4.11_A2.1_T3`, `S15.4.4.11_A3_T1`.)
- **Default compare calls ToString per element.**
  Given two objects whose `toString` bumps a counter,
  When `[object, object].sort()`,
  Then the counter is ≥ 2. (Test262: `bug_596_1`.)
- **Symbol element, default compare.**
  Given `[Symbol(), 1]`, When `.sort()`, Then a `TypeError` is thrown.
- **Comparator returns a Symbol/BigInt.**
  Given `[1, 2]`, When `.sort(() => Symbol())`, Then a `TypeError` is thrown.

## In scope
- `src/builtin_array.zig` `compare` (shared by `sort` and `toSorted`).

## Out of scope (other agents' files / other clusters)
- The `Array/prototype/sort/precise-*` family (~22 tests) — blocked by the array-exotic
  **[[DefineOwnProperty]]** for index accessor/data descriptors and array-exotic **[[Get]]** of an
  inherited index over a hole (see `specs/072-array-define-own-property`). Both live in
  `object.zig`/`interpreter.zig`/`builtin_object.zig`, not the Array prototype module.
- `call-with-primitive` (ToObject must box a Symbol/BigInt into `Symbol.prototype`/`BigInt.prototype`
  — `toObjectForArrayLike` in `interpreter.zig`).
- `comparefn-grow`/`shrink`/`resizable-buffer` (TypedArray/ArrayBuffer).
- `toSorted`/`toReversed`/`with` residual failures (inherited-hole [[Get]], array-index accessors,
  ToObject boxing, `compareArray.js` harness) — all outside the Array prototype module.

## Success criteria
- `built-ins/Array/prototype/sort` passing count increases; `toSorted` unchanged or up.
- `zig build` / `test` / `lint` green; **0 regressions** vs `baseline/language.json`; bench OK.
