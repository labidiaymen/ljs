# Plan: Error subclassing (M77 / 065)

## Approach
`src/interpreter.zig` callNative `.error_ctor` (~6971): when `self.native_new_target != .undefined`
and `this_val == .object`, use `this_val.object` as the error instead of `Object.create(proto)`;
keep the existing error_data/name/message assignment logic unchanged, just targeting that object.
A plain call (no new_target) creates a fresh error as today. (The `aggregate_error_ctor` /
`suppressed_error_ctor` variants are left as-is this cycle — separate, lower-frequency.)

## Files touched
`src/interpreter.zig` (the `.error_ctor` arm only).

## Risks
LOW. Direct `new Error(x)` already runs with native_new_target set and this_val = the fresh
construct instance (proto = Error.prototype via new_target), so it gets the same object identity
and fields as before; only the subclass path changes (was broken). Gate + guards cover it.

## Constitution Check
Correctness leads (§20.5.1.1 / §15.7.14) ✔; perf construct-time only ✔.
