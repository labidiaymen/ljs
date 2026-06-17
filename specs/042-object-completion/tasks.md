# M42 tasks — Object completion

## T1 — engine brand markers (object.zig)
- Add `error_data: bool = false` and `is_arguments: bool = false` to `Object`.
- Set `error_data = true` in the three `*_error_ctor` construct paths + `throwError`.
- Set `is_arguments = true` in `makeArgumentsObject`.

## T2 — §20.1.3.6 Object.prototype.toString (interpreter.zig)
- Replace the `.object_to_string` stub with the full tag algorithm:
  undefined/null short-circuit; ToObject brand probe (Array/Arguments/Function/Error/
  Boolean/Number/String/Object); read `@@toStringTag` (string-only); build `[object <tag>]`.
- Receiver coercion for primitive `this` via `.call(prim)`.

## T3 — new statics: ids + wiring (object.zig NativeId, builtins.zig)
- NativeId: `object_from_entries`, `object_has_own`, `object_get_own_property_symbols`,
  `object_group_by`, `object_proto_getter`, `object_proto_setter`.
- builtins: defineMethod for fromEntries/hasOwn/getOwnPropertySymbols/groupBy on Object;
  define the `__proto__` accessor (configurable, non-enumerable) on %Object.prototype%.

## T4 — static implementations (interpreter.zig)
- `objectFromEntries`, `objectHasOwn`, `objectGetOwnPropertySymbols`, `objectGroupBy`.
- `__proto__` get/set natives → reuse getPrototypeOf / setPrototypeOf ops with B.2.2.1
  no-op semantics on the setter.
- Dispatch the new ids in `callNative`.

## T5 — gates
- zig build / zig build test / zig build lint (0/0).
- Conformance: built-ins/Object passed↑, 0 within-Object regressions; language no-regression.
- Bench: perf ok, ljs ≤ Node.

## Delta (measured per sub-path with a perl wall-clock watchdog; the pre-existing
## `assign/target-Array.js` hang — a ~2^32 array index in `Object.assign`, unrelated to
## M42 — is excluded identically before & after)
- built-ins/Object: 4465 -> 4673 passed / 6800 (65.7% -> 68.7%), +208, **0 regressions**
  (verified by fail-SET diff across subdirs + loose top-level + assign-per-file).
  Big movers: hasOwn +108, prototype +32 (toStringTag toString), fromEntries +32,
  groupBy +14, getOwnPropertySymbols +12, keys +4, create/defineProperties/
  getOwnPropertyNames +2 each.
- language/: **no regression** vs baseline (86.9% -> 87.1%, +116 net).
- methods landed: §20.1.3.6 toStringTag/builtin-tag toString; Object.fromEntries / hasOwn /
  getOwnPropertySymbols / groupBy; §B.2.2.1 `__proto__` accessor.

## T6 — follow-on fix surfaced by the tag-aware toString (in scope, required for 0 regress)
The correct §20.1.3.6 `Object.prototype.toString.call(fn)` = "[object Function]" leaked into
`String(fn)` (functions inherit Object.prototype.toString — no Function.prototype.toString yet),
while computed property keys used a pure ToString that never invoked the method -> the two
disagreed and broke 54 language tests. Root cause: computed keys bypassed §7.1.19 ToPropertyKey.
Fix (more spec-correct):
- `getPropertyV`/`setPropertyV`/`propKey`/`classElementKey` now do §7.1.19 ToPropertyKey
  (ToPrimitive(string) for an object key, RequireObjectCoercible(base) FIRST) via `toPropertyKey`.
- Compound assignment `t op= v` is no longer desugared to `t = t op v` (which re-evaluated a
  side-effecting base/key). New `ast.compound_assign` node + `evalCompoundAssign` evaluate the
  reference ONCE (§13.15.2); `applyNumericOrStringOp` is the shared value-level operator.
  `++`/`--` on an index likewise coerce the key once (`coercePropertyKey`).
- `with` identifier compound assignment re-resolves at PutValue (§9.1.1.2.5 strict ReferenceError
  when a getter deletes its own binding).
