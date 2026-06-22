# Tasks — Spec 124 JIT i64 widening
- [x] Emitter: 64-bit neg/sarImm/addImm/subImm/imulImm + `.a` cond
- [x] compileChunk: 64-bit arithmetic + emitSafeIntGuard (deopt past 2^53)
- [x] Constants/moves/compares/ret to 64-bit; bitwise/shift stay i32 + movsxd
- [x] Verify 2^53-boundary correctness vs Node; -0 deopt
- [x] Gate: test+lint+bench + Test262 (default + LJS_JIT=1 differential), 0 regressions
- [ ] (spec 125) make for(let) JIT; then default-on JIT
