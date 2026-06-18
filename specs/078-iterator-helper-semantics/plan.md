# M76 — Implementation plan

## Files touched
- `src/object.zig` — `nativeLength`: add `.iterator_ctor`→0, `.iterator_from`→1,
  `.iterator_helper`→(toArray 0, else 1), `.iterator_helper_next`→(return 1, else 0).
- `src/runtime_types.zig` — `HelperState`: add `running: bool` (GeneratorValidate reentrancy guard).
- `src/builtin_iterator.zig`:
  - New `closeIteratorNormal(it, iterator)` — §7.4.11 IteratorClose for a NORMAL completion (calls
    `return`, propagating a throwing `return`/getter and a non-Object result). Local to the module
    because the interpreter's equivalent (`iteratorCloseChecked`) is private.
  - `iteratorHelper`: split `toArray` (reads `next` then drains) from the callback helpers, which now
    validate `IsCallable(callback)` (closing on failure with the swallowing close — a THROW
    completion) BEFORE reading `next`.
  - `iteratorLimitHelper` (take/drop): validate the numeric limit (ToNumber/NaN/negative) BEFORE
    reading `next`.
  - `helperNext`: add the `running` reentrancy guard (TypeError if set); set/clear `running` around
    the per-kind pull via `defer`; route the helper's own `return()` and `take`'s exhaustion close
    through `closeIteratorNormal` so a throwing underlying `return` propagates.
- `src/builtin_symbol.zig` — `constructor`: use `it.toStringThrowing(args[0])` for ToString(description).

## Design calls
- The callback-invalid IteratorClose stays the swallowing `it.iteratorClose` (it is an
  IteratorClose with a THROW completion — §7.4.11 step 4 discards a throwing `return`). Only the
  NORMAL-completion closes (`return()`, take-exhaustion) propagate.
- `running` is cleared with `defer` so every abrupt/return path resets it; it is NOT set on the
  `return()` branch (which only closes, it does not resume the body).

## Constitution Check
- Correctness-first: pure conformance fixes, no behavior shortcuts.
- Perf no-regression: the only hot-path-adjacent change is the extra `length` define on native
  creation (constant cost, mirrors existing natives) — bench confirms perf:ok.
- No forbidden files edited; interpreter-level root causes are REPORTED, not patched.
