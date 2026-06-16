---
description: "Task list for M6 — reflection / property-descriptor built-ins (§6.1.7.1, §10.1, §20.1.2/§20.1.3, §20.2.3, conformance-driven)"
---

# Tasks: M6 — Reflection / Property-Descriptor Built-ins

**Metric:** conformance is reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`, the standard Test262 way), same as M4/M5. The continuity gate is
`language/expressions`; the committed baseline `baseline/language-expressions.json` (M5 close: passed
**6077**, **35.8%**) is the floor — M6 must hold it and (once propertyHelper.js fully loads) push it UP.

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + **bench (ljs ≤ Node, no
data-prop fast-path regression)** green). Re-measure `language/expressions` (continuity gate) each cycle.

**Mandatory regression hunt (every cycle):** the descriptor model + enumerability change touches every
object property engine-wide → high regression risk. Capture the per-test result set (by `mode+path`)
before and after each change (`git stash` the worktree, rebuild ReleaseFast, `--update-baseline` to a
JSON pass-id set, `comm`); true-regressions must be 0 or far outweighed by recoveries. Do NOT commit a
net regression on the continuity gate.

## Cycle 1 — descriptor model + `Object` reflection + enumerable-awareness (US1+US2+US3+US4) 🎯 (DONE — continuity gate (`language/expressions`, harness): passed 6077 → **6139** (+62), **0 true regressions / 62 recoveries** by `mode+path`; conformance 35.8% → **36.2%**. Recoveries: 16 `class`, 14 `object`, 8 `delete`, 6 `logical-assignment`, 4 each `array`/`arrow-function`/`function`/`instanceof`, 2 `assignment` — tests that use `Object.defineProperty`/`getOwnPropertyDescriptor`/`getOwnPropertyNames`/`hasOwnProperty`/`propertyIsEnumerable` directly. propertyHelper.js module-top now clears its `Object.*` / `Object.prototype.*` reflection deps (lines 28–30, 33–34) — the LAST blocker is `Function.prototype.call.bind` (line 31, Cycle 2). Committed baseline bumped 6077 → 6139.)
- [x] M6-T010 **Property-descriptor model (§6.1.7.1)** — extend `src/object.zig` `PropertyValue` from a
  bare `{data}|{accessor}` union to a struct carrying the data/accessor payload PLUS `writable`
  (data only), `enumerable`, `configurable`. The hot `get`/`set` data read stays a single `switch` on
  the payload kind (attributes are not branched on for plain reads — bench gate). Ordinary creation
  (`set`, object-literal, class field, array element) defaults all attributes to **true**. New
  descriptor-aware API on `Object`: `defineData(key, value, attrs)` / `defineOwnAccessor` /
  `getOwnAttrs` / `isEnumerable(key)` and a `defineProperty` implementing §10.1.6
  OrdinaryDefineOwnProperty (new prop → omitted attrs default false; existing prop → keep unstated;
  basic non-configurable TypeError). `defineAccessor` (object-literal getters/setters) keeps
  enumerable+configurable true.
- [x] M6-T020 **Built-in prototype methods non-enumerable (§20.1.3 etc.)** — `src/builtins.zig` installs
  every prototype method (String/Array/Object/Error prototypes, the new `Object`/`Object.prototype`
  reflection methods) as non-enumerable (writable+configurable per spec). A `defineMethod` helper sets
  `{enumerable:false, writable:true, configurable:true}`. This is what makes `for (k in [])` /
  `for (k in {})` correctly empty via the per-property flag (the M5 stop-at-builtin-proto heuristic stays
  as a cheap short-circuit but correctness now comes from `[[Enumerable]]`).
- [x] M6-T030 **`Object` static reflection (§20.1.2)** — new `NativeId`s + `callNative` dispatch:
  `object_define_property` (§20.1.2.4 ToPropertyDescriptor → `defineProperty`),
  `object_get_own_property_descriptor` (§20.1.2.8 → FromPropertyDescriptor: a fresh
  `{value,writable,enumerable,configurable}` / `{get,set,enumerable,configurable}` object, or
  `undefined`), `object_get_own_property_names` (§20.1.2.10 → all own string keys incl. non-enumerable;
  arrays: indices + `"length"`), `object_define_properties` (§20.1.2.5). Installed on the `Object`
  constructor.
- [x] M6-T040 **`Object.prototype` reflection (§20.1.3)** — `object_has_own_property` (§20.1.3.2,
  own-only), `object_property_is_enumerable` (§20.1.3.4), `object_is_prototype_of` (§20.1.3.3), all
  non-enumerable methods on `Object.prototype`. Boxing for a String `this` (index/length keys);
  number/boolean → no own keys.
- [x] M6-T050 **Enumerable-awareness (§7.3.25 / §14.7.5)** — `enumerateKeys` (for-in) and
  `copyDataProperties` (object spread `{...o}`) skip non-enumerable own properties via the new
  `isEnumerable` check (for-in still walks inherited enumerable keys; spread is own-only). Array indices
  / String chars stay enumerable; Array `length` non-enumerable.
- [x] M6-T060 **Tests (`src/engine.zig`, all green)** — `Object.defineProperty(o,'x',{value:5,
  enumerable:false}); o.x` → 5 and for-in over it yields only the enumerable keys; `getOwnPropertyDescriptor`
  value + flags (omitted → false); a getter via `defineProperty` invoked on read; `getOwnPropertyNames`
  includes a non-enumerable name; `hasOwnProperty` own-true / inherited-false; `propertyIsEnumerable`;
  `isPrototypeOf`; `defineProperties`; redefine-non-configurable throws; `for (k in {a:1})` yields only
  `"a"` (no proto methods); `{...{a:1}}` only `a`.
- [x] **Conformance + regression hunt (harness metric, ReleaseFast, `comm` of the `--update-baseline`
  pass-id sets):** continuity gate `language/expressions` `passed 6077 → 6139` (+62), conformance 35.8%
  → 36.2% — **0 true regressions / 62 recoveries** by `mode+path`. The descriptor + enumerability change
  recovered every test that uses `Object.defineProperty`/`getOwnPropertyDescriptor`/`getOwnPropertyNames`/
  `Object.prototype.hasOwnProperty`/`propertyIsEnumerable` DIRECTLY (16 `class`, 14 `object`, 8 `delete`,
  6 `logical-assignment`, 4 each `array`/`arrow-function`/`function`/`instanceof`, 2 `assignment`).
  propertyHelper.js's module top now gets PAST `Object.defineProperty`/`getOwnPropertyDescriptor`/
  `getOwnPropertyNames` (lines 28–30) and the `Object.prototype.hasOwnProperty`/`propertyIsEnumerable`
  methods exist (lines 33–34) — verified by a direct eval (`typeof Object.defineProperty === 'function'`,
  etc.). The LAST blocker is line 31 `Function.prototype.call.bind(...)` (`typeof Function.prototype.call
  === 'undefined'` — no call/apply/bind yet) → `verifyProperty` not yet callable; the FULL propertyHelper.js
  unblock lands in Cycle 2. Built-in prototypes were chained to `%Object.prototype%` (§23.1.3/§22.1.3/
  §20.5.3.1) so inherited reflection methods resolve on arrays/strings/errors; the non-enumerable flag
  keeps the chained inheritance out of for-in/keys (0 regressions confirms it). Bench green (data-prop
  fast path held — loop_mix −4.5% / loop_sum +1.9% / str_build −13.9% vs base, all `ok`; ljs 0.2–0.6×
  Node). Committed baseline bumped 6077 → 6139.
- [x] **Landed:** §6.1.7.1 per-property attributes (writable/enumerable/configurable, ordinary creation =
  all true); built-in proto methods non-enumerable; `Object.defineProperty` (data + accessor, new→false
  defaults, basic non-configurable guard) / `getOwnPropertyDescriptor` / `getOwnPropertyNames` /
  `defineProperties`; `Object.prototype.hasOwnProperty`/`propertyIsEnumerable`/`isPrototypeOf`;
  enumerable-aware for-in + object spread. **Deferred (Cycles 2–3 below):** `Function.prototype.call`/
  `apply`/`bind` (the remaining propertyHelper.js blocker); `Object.keys`/`values`/`entries`/`create`/
  `assign`/`freeze`/`getPrototypeOf`/`setPrototypeOf`; `preventExtensions`/`seal`/extensibility
  enforcement; strict `[[Set]]` non-writable rejection; the full §10.1.6.3 invariant matrix; Symbol /
  integer-key ordering.

## Cycle 2 — `Function.prototype.call` / `apply` / `bind` (§20.2.3) — completes the propertyHelper.js unblock
- [ ] M6-T110 A real `Function.prototype` object (global `Function` ctor), carrying non-enumerable
  `call` (§20.2.3.3), `apply` (§20.2.3.1), `bind` (§20.2.3.2). `call`/`apply` re-dispatch to
  `callFunction` with the given receiver + args; `bind` returns a bound-function exotic (prepends bound
  args, fixes `this`). Function objects proto-link to `Function.prototype` so `f.call`/`f.bind` resolve.
  Expected: propertyHelper.js fully LOADS and `verifyProperty` becomes callable → the `class/*`
  `verifyProperty` positives in `language/expressions` recover (the main M6 conformance lever). Bench +
  regression hunt gated as always.

## Cycle 3 — `Object.keys`/`values`/`entries`/`create`/`assign`/`freeze`/`getPrototypeOf`/`setPrototypeOf` + close
- [ ] M6-T210 `Object.keys`/`values`/`entries` (§20.1.2.16/.21/.5 — own enumerable string keys/values/
  pairs), `Object.create` (§20.1.2.2 — new object with the given proto + optional property descriptors),
  `Object.assign` (§20.1.2.1 — copy own enumerable into target), `Object.getPrototypeOf`/`setPrototypeOf`
  (§20.1.2.12/.23), `Object.freeze`/`isFrozen` + `preventExtensions`/`isExtensible` (§20.1.2.6/.11) with
  the extensibility + non-writable enforcement the freeze tests need. Close the milestone with the final
  conformance delta + regression hunt.

## Dependencies / order
Ordered by impact-to-effort and spec layering: the descriptor model + `Object` reflection + enumerable-
awareness first (Cycle 1 — the model every later piece builds on, and it gets propertyHelper.js's module
top past the `Object.*` calls), then `Function.prototype.call`/`apply`/`bind` (Cycle 2 — the last
propertyHelper.js blocker, the recovery lever), then the remaining `Object.*` enumeration/creation API
(Cycle 3). Each cycle bench-gated (data-prop fast path is the watch item); each runs the before/after
regression hunt by `mode+path`.
