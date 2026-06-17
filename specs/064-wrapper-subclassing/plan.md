# Plan: Primitive-wrapper subclassing (M76 / 064)

## Approach
`src/interpreter.zig` callNative: `number_ctor`/`string_ctor`/`boolean_ctor` compute the coerced
primitive as today, but if `self.native_new_target != .undefined and this_val == .object`, set
`this_val.object.primitive = prim` and return `this_val`; else return the primitive. Mirrors the
Array (M75) and collection ctors. Remove the now-redundant `new_obj.primitive = result.normal`
boxing in `constructNT` (~1824) — the native now boxes the instance directly (and would otherwise
double-box the object onto itself).

## Files touched
`src/interpreter.zig` (the three wrapper ctor arms + delete the constructNT 1824 boxing line).

## Risks
LOW. Direct `new Wrapper(x)` still boxes (native_new_target is set in constructNT) and returns the
instance via the explicit-object-return path; plain calls unchanged. Regression guards + gate cover.

## Constitution Check
Correctness leads (§20.3/§21.1/§22.1 + §15.7.14) ✔; perf construct-time only ✔.
