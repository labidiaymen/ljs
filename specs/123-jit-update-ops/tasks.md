# Tasks — Spec 123 JIT i++/i--
- [x] Diagnose: idiomatic for-loops bail because compiler `.update` → fail()
- [x] Compile `.update` on slot identifiers (load; pos; [dup]; const1; add/sub; store)
- [x] Verify prefix/postfix value semantics vs Node (tree-walk + VM + JIT)
- [x] Gate: test+lint+bench + Test262 (0 regressions); ~200x on idiomatic counter loops
- [ ] (spec 124) i32→i64 widening so accumulators don't deopt on overflow
