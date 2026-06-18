# Spec 072 — Array [[DefineOwnProperty]] + Reflect.set receiver semantics

Status: Done — Object 5407→5535 (+128), Reflect 248→260 (+12); language 90.3%, 0 regressions.

## Summary
Two property-descriptor root-cause clusters across `built-ins/Object` and `built-ins/Reflect`:

1. **§10.4.2.1 Array exotic [[DefineOwnProperty]] for integer indices.**
   `Object.defineProperty(arr, i, desc)` and `Object.defineProperties(arr, …)` stored the index in
   the ordinary property map only — the array's dense element store and `[[Length]]` were never
   updated. So `arr[i]` (which the interpreter reads from the dense store) ignored the define, and
   defining an index past the end did not grow `length`. `Object.defineProperties` additionally never
   routed an array `length` define through ArraySetLength.

2. **§10.1.9 Reflect.set receiver redirection.**
   `Reflect.set(target, key, value, receiver)` ignored a distinct `receiver`: a data write always
   went to `target`, never to the receiver (and a non-object receiver did not return `false`).

## Governing clauses
- §10.4.2.1 Array Exotic Object [[DefineOwnProperty]]; §10.4.2.4 ArraySetLength.
- §10.1.6.3 ValidateAndApplyPropertyDescriptor (redefinition guards).
- §10.1.9 / §10.1.9.2 OrdinarySet / OrdinarySetWithOwnDescriptor (receiver redirection).
- §28.1.13 Reflect.set; §28.1.3 Reflect.defineProperty.

## User scenarios (Given/When/Then, derived from Test262)
- Given `var a=[0,1,2]`, When `Object.defineProperty(a,"4",{value:7,writable:true,enumerable:true,
  configurable:true})`, Then `a[4]===7` and `a.length===5`. (Object/defineProperty, defineProperties
  `15.2.3.6-3-*`, `15.2.3.7-6-a-*`.)
- Given `var a=[0,1]`, When `Object.defineProperties(a,{length:{value:null}})`, Then `a.length===0`.
- Given `var o={p:43}` and `Reflect.set(o,'p',42)` (no receiver), Then `o.p===42` and result `true`.
- Given a `target` with a data `p` and a distinct `receiver`, When `Reflect.set(target,'p',v,receiver)`,
  Then the value lands on `receiver` (not `target`) and `target.p` is unchanged.
- Given a primitive `receiver`, When `Reflect.set(target,'p',v,receiver)`, Then it returns `false`.
- Given `receiver.p` is an accessor / non-writable data property, Then `Reflect.set` returns `false`.

## In scope
- Integer-index `[[DefineOwnProperty]]` against the dense/sparse element store + `[[Length]]` growth,
  with §10.1.6.3 redefinition validation; non-default-attribute / accessor indices fall back to the
  ordinary property map (single source of truth, no dense double-count).
- `Object.defineProperties` array `length` + index routing.
- `Reflect.set` receiver redirection (string + symbol keys); `Reflect.defineProperty` integer-index
  routing into the array path.

## Out of scope (M-subset limitations, documented)
- Per-index `[[Writable]]`/accessor divergence is not observable through the interpreter's dense-only
  array index *read*/*write* path (only `Object`/`Reflect` reflection sees the map-stored attributes).
- Proxy non-`get` traps (separate interpreter-routing work, not in these files).

## Success criteria
- `built-ins/Object` and `built-ins/Reflect` pass counts increase; **0 regressions** vs the
  `baseline/language.json` baseline over `test/language`.
