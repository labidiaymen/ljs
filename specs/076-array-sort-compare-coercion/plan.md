# Plan 076 — Array sort SortCompare coercion fidelity

## Approach
Single function: `compare` in `src/builtin_array.zig` (the §23.1.3.30.1 SortCompare used by both
`sort` and `toSorted`). `compare` already returns `CompareResult = union(enum){ order: i32,
abrupt: Completion }`, so threading abrupt completions out is free.

### Edits
1. **Comparator path.** Replace `ops.toNumber(r.normal)` (non-throwing) with
   `it.toNumberThrowing(r.normal)` (returns a `Completion`); on abrupt, return `.{ .abrupt = c }`.
   A returned NaN still maps to order 0.
2. **Default path.** Replace `it.toString(x)` / `it.toString(y)` (the `ops.toString` shortcut that
   yields `"[object Object]"` for objects and silently stringifies Symbols) with
   `it.toStringThrowing(...)` (full §7.1.17 ToString: ToPrimitive(string) on objects, TypeError on
   Symbols); propagate abrupt, then code-unit-order the resulting strings.

Both helpers (`toNumberThrowing`, `toStringThrowing`) are already public on `Interpreter`.

## Files touched
- `src/builtin_array.zig` (only `compare`).

## Design calls
- `sort`/`toSorted` both reach `compare`; one fix covers both.
- Abrupt completions from the new throwing coercions surface through the existing insertion-sort
  loops, which already check `switch (try compare(...)) { .abrupt => |c| return c, .order => ... }`.

## Constitution Check
- **Correctness leads:** pure spec-fidelity fix; no behavior change for the common all-number /
  all-string sort path (those coercions never throw and never hit the object branch).
- **Perf:** for non-object, non-Symbol elements `toStringThrowing` resolves to the same ordinary
  ToString; the comparator path adds one already-cheap `toNumberThrowing` over a primitive. No
  hot-path regression — bench must stay green (absolute pre-commit gate).
