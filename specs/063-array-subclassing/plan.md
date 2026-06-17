# Implementation Plan: Array subclassing (M75 / 063)

## Approach
`src/interpreter.zig` `callNative` `.array_ctor` arm (~6788): mirror the collection-ctor pattern.
When `self.native_new_target != .undefined` and `this_val == .object`, use that instance as the
array (flip `kind = .array`) instead of allocating a fresh array; otherwise (plain `Array(...)`
call) allocate fresh as today. Then apply the existing §23.1.1.1 single-number-length /
elements rule to that object. Return the object.

This works because:
- The derived/new instance is created in `constructNT` proto-linked to `new_target.prototype`,
  and a plain object from `Object.create` has the same zero-init array backing fields that
  `Object.createArray` relies on — so flipping `kind` is sufficient to make it an Array exotic.
- For a DIRECT `new Array(n)`, `native_new_target` is also set, so the instance (proto =
  Array.prototype) is initialized and returned — identical observable result to today's fresh
  array, but now it IS the constructed instance.
- For `super(n)` from `class S extends Array`, `this_val` is the derived instance → it becomes
  the array, so `new S(n).length` works.

## Files touched
`src/interpreter.zig` (the `.array_ctor` callNative arm only).

## Risks
- LOW. `Array(...)` plain-call path unchanged. The new/super path now initializes the instance
  in place rather than returning a throwaway array — same length/element semantics. Regression
  guards (literals, of/from, spread, isArray) + conformance gate cover it.

## Constitution Check
- Correctness leads: §23.1.1.1 / §15.7.14. ✔  • Perf: construct-time only. ✔
