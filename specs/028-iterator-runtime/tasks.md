# M28 — Tasks

- [x] T1 Build ReleaseFast; capture full `language/` baseline (passed=33083, 75.8%).
- [x] T2 Categorize the iterator bucket (for-of / for-await-of / async-generator).
      Finding: parse_error DOMINATES (1048; 553 unique, 543 `dstr/*`), not runtime.
- [x] T3 Reproduce minimally OUTSIDE for-of — three independent parse gaps:
      - DestructuringAssignment pattern in the for-head (`for ([a] of …)` / `for ({a} of …)`)
      - computed / numeric object BINDING-pattern keys (`var { [k]: x }`, `var { 0: v }`)
      - parenthesized inner default clobbering the cover-grammar refinement (`[a = (1)] = []`)
- [x] T4 Fix #1 — for-head AssignmentPattern.
      - [x] parser: refine an un-parenthesized array/object literal head via
            `validateAssignmentPattern` instead of `isSimpleAssignTarget` (`src/parser.zig`)
      - [x] interpreter: route an array/object-literal head through `assignPattern`
            (§13.15.5.2 + §7.4.11 IteratorClose) in `bindForHead` (`src/interpreter.zig`)
- [x] T5 Fix #2 — computed / numeric binding-pattern keys.
      - [x] AST: `ObjectBindingProperty.computed: ?*const Node` (`src/ast.zig`)
      - [x] parser: `parseObjectPattern` reuses `parsePropertyName`; no shorthand for
            string/numeric/computed names (`src/parser.zig`)
      - [x] interpreter: evaluate computed key once (ToPropertyKey), `getPropertyV`,
            exclude resolved key from BindingRestProperty (`src/interpreter.zig`)
- [x] T6 Fix #3 — clear `last_was_paren` at the end of array/object literal parsing
      (`src/parser.zig`); verify `({a}) = x` still rejected.
- [x] T7 Harness: make `regressionsVs` O(results + baseline) via a passing-id hash set
      (`test262/report.zig`) — the quadratic form OOM-killed the gate at corpus scale.
- [x] T8 Add `src/engine.zig` tests: for-head pattern + IteratorClose-on-throw,
      computed/numeric binding keys + rest exclusion, IteratorClose-on-break,
      non-Object next() result → TypeError, string iteration.
- [x] T9 Gates: build / test / lint(0,0) / conformance (≥33083, no regression) / bench.
- [x] T10 Update baseline; commit if all green.
