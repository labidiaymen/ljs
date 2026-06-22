# Tasks — Spec 122 lazy arguments
- [x] FunctionData.arg_state cache (unknown/needed/not_needed)
- [x] Conservative AST scan (arguments ref / direct eval / with; descend arrows, not nested fns)
- [x] callFunction skips makeArgumentsObject when not needed
- [x] Verify arguments-using functions still correct
- [x] Gate: test+lint+bench + Test262 (0 regressions, +8); ~4x faster calls
