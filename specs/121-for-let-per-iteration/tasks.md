# Tasks — Spec 121 for-let per-iteration binding
- [x] createPerIterationEnvironment: fresh env per iteration copying loop-head bindings
- [x] Install before first iteration + before each update (§14.7.4.2)
- [x] Perf guard: mayCreateClosure body scan — skip the copy for closure-free bodies
- [x] Verify 0,1,2 for arrow + funcdecl closures; closure-free let-loop == var-loop speed
- [x] Gate: test + lint + bench + Test262 language differential (0 regressions)
