# Tasks — Spec 112

## Tier 0 — x86-64 emitter (this cycle)
- [x] `src/jit_x64.zig`: `Reg`/`Cond` + `Emitter` (mov/zero/add/sub/imul/cmp/cmpImm/push/pop/ret/jmp/jcc/patch)
- [x] `makeExecutable` (VirtualAlloc RWX → callable pointer; Windows)
- [x] Unit test: emit `sum` loop, execute, assert `sum(5000)=12497500`, `sum(0)=0`, `sum(10)=45`
- [x] Wire `_ = @import("jit_x64.zig")` into `src/root.zig` test block
- [x] `zig build test` green; `zig build lint` green; default build unaffected

## Tier 1 — integer JIT (next cycle)
- [ ] `src/jit.zig`: compile bytecode integer-subset → native via the emitter
- [ ] Register allocation: slots → callee-saved regs (push/pop prologue/epilogue), operand stack → caller-saved
- [ ] SMI entry guard (args are safe integers) + overflow→deopt (≤2^53, f64-exact)
- [ ] Deopt path: signal caller to fall back to the VM / tree-walk on guard miss / unsupported op
- [ ] Value↔i64 marshalling at the call boundary; box i64 result → number
- [ ] Wire into `callFunction` behind `LJS_JIT` (off by default)
- [ ] Re-prove beats Node in-engine on the 1e9-iter loop; differential Test262 `LJS_JIT=1` = 0 regressions; bench no-regression

## Tiers 2–4 — roadmap (own specs)
- [ ] Tier 2: SSE2 f64 + int↔float + `Math.*`
- [ ] Tier 3: strings / arrays / typed-arrays (the uuid-formatting tier)
- [ ] Tier 4: objects + inline caches / type feedback (TurboFan-equivalent)
