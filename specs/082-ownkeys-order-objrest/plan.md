# Plan — 082

## Approach
1. `src/object.zig`: add `canonicalArrayIndex(key) ?u32` (strict §6.1.7 — no leading zeros, < 2^32−1)
   and `orderedStringKeys(arena) [][]const u8` (integer keys ascending, then rest in insertion order).
2. `src/interpreter.zig`:
   - `enumerateKeys`: ordinary-object branch iterates `orderedStringKeys` instead of the raw map iterator.
   - `ordinaryOwnKeys`: ditto, before the symbol keys (which already come last).
   - Replace the open-coded `copyDataProperties` with `copyDataPropertiesExcluding(target, source,
     excluded)` returning `?Completion` (null = ok). It walks `ordinaryOwnKeys` (so: spec order +
     symbols + array indices), filters by own-enumerable via `ordinaryGetOwnProperty[Symbol]`, copies
     via [[Get]], honors the exclusion set (string keys only), and propagates abrupt completions.
   - Route the object-literal spread caller, the `bindPattern` BindingRestProperty, and the
     `assignPattern` AssignmentRestProperty through the new helper. BindingRestProperty rest object now
     uses `%Object.prototype%`. The assignment-rest exclusion set is accumulated in the single forward
     property loop (computed keys evaluated exactly once — no double evaluation).

## Files / functions touched
- `src/object.zig`: `canonicalArrayIndex`, `orderedStringKeys` (new).
- `src/interpreter.zig`: `enumerateKeys`, `ordinaryOwnKeys`, `copyDataProperties`(+`Excluding`),
  `evalObjectLiteral` spread arm, `bindPattern` object-rest arm, `assignPattern` object-rest arm.

## Design calls
- `orderedStringKeys` fast-paths the common no-integer-key case (returns the insertion-order slice
  unchanged), so the hot object path pays only a single linear scan + an allocation-free early return.
- Keep the builtins-area duplicate collectors untouched (scope boundary); flag as a follow-up.

## Constitution check
- Correctness-leads: all changes are pure spec-fidelity (ordering, symbol inclusion, throw
  propagation, correct rest prototype). No new deviations.
- Perf no-regression: the only hot path is ordinary-object enumeration; `orderedStringKeys` early-exits
  when there are no integer keys. Bench gate must stay green.
