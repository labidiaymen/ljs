# Plan — Spec 112 Tier 0 (x86-64 emitter)

## Files
- **`src/jit_x64.zig`** (new): the emitter.
  - `Reg` (16 GPRs, REX-aware `low()`/`ext()`), `Cond` (jcc condition codes).
  - `Emitter` over a growable `[]u8`: `movImm`/`movReg`/`zero`/`add`/`sub`/`imul`/`cmp`/`cmpImm`/
    `push`/`pop`/`ret`/`jmp`/`jcc`/`patch` (rel32 label fixups). Register-only (no memory operands)
    — the JIT keeps slots in callee-saved regs and the operand stack in caller-saved regs, which is
    both faster and sidesteps SIB/ModRM-memory encoding.
  - `makeExecutable(F, code)`: `VirtualAlloc` RWX (Windows; `?F` null elsewhere) → callable pointer.
  - Unit test: build a `sum` loop via the API, run it, assert results.
- **`src/root.zig`**: add `_ = @import("jit_x64.zig");` so `zig build test` runs the emitter test.

## Design calls
- **Register-only codegen.** Avoids memory addressing entirely for Tier 0/1; matches the validated
  POC (everything in registers) and keeps the encoder small. Memory spill is a later-tier concern.
- **Win64-only for now.** Dev target; `callconv(.c)` on x86_64-windows = the Microsoft ABI (arg in
  RCX, return in RAX). The byte encoding is standard x86-64, so a SysV variant is additive.
- **No instruction-cache flush.** Freshly `VirtualAlloc`'d pages have no stale I-cache lines on
  x86-64; the POC + unit test confirm correct execution without `FlushInstructionCache`.
- **Isolated-first (like the VM's Phase 0a).** A machine-code bug crashes the whole process, so the
  emitter is proven by unit test in isolation before any `callFunction` wiring (Tier 1).

## Constitution Check
- **Correctness-leads:** the emitter is pure infrastructure, called only from tests — it cannot
  affect interpretation or conformance. Default `zig build` behavior is byte-identical.
- **Perf no-regression gate:** no hot-path code touched; bench unaffected (nothing on the eval path
  changes). Re-run `zig build bench` before commit regardless.
- **Test262:** zero exposure — the emitter is not reachable from `evaluate*`.

## Risks
- **Encoding bugs → crashes.** Mitigated by the unit test executing the emitted code and checking
  results (caught a `u6`/`u5` loop-counter overflow during dev). Future ops get the same treatment:
  emit → execute → assert.
