# Tasks — Spec 112

## Tier 0 — x86-64 emitter (this cycle)
- [x] `src/jit_x64.zig`: `Reg`/`Cond` + `Emitter` (mov/zero/add/sub/imul/cmp/cmpImm/push/pop/ret/jmp/jcc/patch)
- [x] `makeExecutable` (VirtualAlloc RWX → callable pointer; Windows)
- [x] Unit test: emit `sum` loop, execute, assert `sum(5000)=12497500`, `sum(0)=0`, `sum(10)=45`
- [x] Wire `_ = @import("jit_x64.zig")` into `src/root.zig` test block
- [x] `zig build test` green; `zig build lint` green; default build unaffected

## Tier 1 — integer JIT (this cycle)
- [x] `src/jit.zig`: compile bytecode integer-subset → native via the emitter
- [x] Register allocation: slots → callee-saved regs (push/pop prologue/epilogue), operand stack → caller-saved
- [x] SMI arithmetic: 32-bit ops + single `jo` overflow→deopt (i32 SMI window = f64-exact, exactly V8's window)
- [x] Peepholes: direct slot compound-update (`x = x OP v` → `op32 slotReg, v; jo`) + assignment-discard (`dup;store;pop`)
- [x] Entry SMI guard (every arg a safe integer) at the call boundary; box i32 result → number
- [x] Deopt path: native sets `*deopt`; caller falls back to the **tree-walk** (never the VM) on miss/overflow/`return undefined`
- [x] Wire into `callFunction` behind `LJS_JIT` (off by default); independent of the bytecode VM
- [x] Beats Node in-engine on the isolated 1e9-iter loop: **820 ms vs Node 1208 ms (1.47×)**; bench no-regression
- [x] Soundness: reject duplicate params (compiler), deopt on `-0` product, reject `-0` arg at the SMI guard
- [x] Differential Test262 `LJS_JIT=1` = **0 regressions** (42308 pass; default path unchanged, JIT off by default)

## Tier 1.5 — broaden the integer subset (this cycle)
- [x] Bitwise `& | ^` (clean i32, no guard) — native `and32`/`or32`/`xor32`
- [x] Unary `-` (neg, with -0 + i32_min overflow deopt) and `+` (identity no-op)
- [x] Unit tests + in-engine JIT-vs-tree-walk parity (bitops/hash/neg); differential `LJS_JIT=1` 0 regressions
- [ ] Deferred: `~` (needs compiler+VM `bit_not` support), `div`/`mod`

## Tier 1.6 — constant-count shifts (this cycle)
- [x] `<< >> >>>` by a constant via the immediate shift form (`shlImm32`/`sarImm32`/`shrImm32`) — no CL
- [x] Peephole `<a>, load_const C, shift` → shift a by `C & 31`; `>>` arithmetic, `>>>` logical + deopt if result ≥ 2^31
- [x] Variable-count shifts bail (would need CL); unit tests + in-engine parity (fnv/pack/`>>>`) + differential 0 regressions

## Tiers 2–4 — roadmap (own specs)
- [ ] Tier 2: SSE2 f64 + int↔float + `Math.*`
- [ ] Tier 3: strings / arrays / typed-arrays (the uuid-formatting tier)
- [ ] Tier 4: objects + inline caches / type feedback (TurboFan-equivalent)
