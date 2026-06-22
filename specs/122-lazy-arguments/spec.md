# Spec 122 — lazy `arguments` materialization (call-path perf)

**Status:** Done (2026-06-22). Part of the `/loop until ljs beats Node` perf drive. ~4× faster
function calls by only building the `arguments` exotic when the function actually uses it.

## Problem
`callFunction` built an `arguments` exotic Object (with indexed own properties for every arg) on
EVERY non-arrow call — even when the body never references `arguments`. V8 materializes it lazily.
Measured: a call-heavy microbench (12M calls) took 27,622ms; skipping `arguments` dropped it to
~6,800ms — i.e. the always-on `arguments` alloc was ~75% of call cost. Express is call-heavy, so this
is a primary reason ljs+Express trailed Node+Express ~2.16×.

## Fix
`FunctionData.arg_state` (unknown→needed/not_needed), computed once per function: a conservative AST
scan (`argsFnUses`) over the body + default-param initializers for an `arguments` reference, a direct
`eval(...)`, or a `with` — descending arrows (they inherit `arguments`) but NOT nested non-arrow
functions / classes (those bind their own). Any unhandled node ⇒ "needed" (never a false negative).
`callFunction` skips the `makeArgumentsObject` alloc when not needed.

## Result
- Call microbench: 27,622ms → ~6,890ms (**~4×**). `arguments`-using functions unchanged + correct.
- 0 Test262 regressions; `zig build bench` no regression.

## Out of scope (future perf cycles toward Node)
Per-call Environment hashmap (slot-based locals), property-access inline caches, the loop JIT.
