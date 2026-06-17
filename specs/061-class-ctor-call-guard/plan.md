# Implementation Plan: Class constructor [[Call]] guard (M73 / 061)

## Approach

Move the §15.7.14 class-constructor [[Call]] guard into `callFunction` (the single [[Call]]
chokepoint), gated on the `pending_new_target` it already consumes — so every entry path
(direct, call/apply/bind, optional-call) is covered, while [[Construct]] (which sets
`pending_new_target`) is not.

### `src/interpreter.zig` — `callFunction` (~2665)
Right after the existing `const pending_new_target = self.pending_new_target; self.pending_new_target = .undefined;` and BEFORE the bound-function unwrap:

```zig
// §15.7.14: a class constructor's [[Call]] always throws — only [[Construct]] (a preceding
// `construct` that handed off [[NewTarget]]) runs its body. `pending_new_target == undefined`
// ⇒ this is a plain [[Call]] (direct, or via call/apply/bind), so reject it.
if (pending_new_target == .undefined) {
    if (func.call) |fd| if (fd.is_class_ctor)
        return self.throwError("TypeError", "Class constructor cannot be invoked without 'new'");
}
```

A bound class constructor has `func.bound != null` and `func.call == null`, so the check is a
no-op on the wrapper and fires on the unwrapped target after the recursive `callFunction`
(which runs with `pending_new_target` already cleared to undefined).

### Redundant checks
The pre-dispatch checks in `evalCall` (~2646) and the optional-call path (~2135) become
redundant. Leave them — they short-circuit a hair earlier on the direct path and are harmless;
removing them is a cosmetic cleanup not worth the regression surface this cycle.

## Risks
- LOW. The only behavioral change: a class ctor reached via call/apply/bind now throws (was a
  silent no-op). `new`/`super` set `pending_new_target`, so they are unaffected — covered by the
  regression guards in spec.md and the conformance gate.

## Constitution Check
- Correctness leads: implements §15.7.14. ✔
- Perf: one extra branch on the [[Call]] path, reading an already-touched field; bench-gated. ✔
