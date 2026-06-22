# Spec 124 — JIT i64 widening: accumulators stop deopting on i32 overflow

**Status:** Done (2026-06-22). Second JIT cycle. The integer JIT now does 64-bit arithmetic guarded to
the safe-integer range, so real accumulators (`sum += i`) run JIT'd at Node speed instead of deopting.

## Problem
The JIT was i32-only: an op set OF on i32 overflow and `jo` deopted to the tree-walk. Any accumulator
exceeding 2^31 (~2.1e9) deopted — e.g. `sum(5e6)` = 1.25e13 tree-walked ~99% of its iterations
(27,820ms). The JIT was effectively useless for real numeric loops.

## Fix
- `jit_x64.zig`: 64-bit `neg`, `sarImm`, `addImm`, `subImm`, `imulImm`; `.a` (unsigned-above) condition.
- `jit.zig` `compileChunk`: every register holds a full i64. `+ - *` use the 64-bit ops + a SAFE-INTEGER
  deopt guard — `emitSafeIntGuard` (`tmp=v; sar tmp,53; add tmp,1; cmp tmp,1; ja deopt`) deopts exactly
  when |v| >= 2^53, using a free stack reg (no 64-bit immediate, no reserved register). Constants load
  full i64 (`movImm`), slot/stack moves + compares are 64-bit, `ret` copies the i64 (not `movsxd`).
  Bitwise/shift stay 32-bit (ToInt32) + `movsxd` back to a valid i64. `neg` keeps the −0 deopt.

## Result
- `sum(5e6)` = 12499997500000 (correct): **27,820ms (deopt) → 125ms** under LJS_JIT (~222×; Node 84ms).
- Correctness vs Node verified at the 2^53 boundary: `mul(1e8,1e8)`, `add(2^53-2,4)`, `mul(94906267²)`,
  `-2^53`, sum-of-squares, and a 200×2^46 accumulator that crosses 2^53 — all match Node's f64 (the JIT
  deopts past 2^53). `-0` from `-1*0` correctly deopts (Object.is === -0; the "0" print is a pre-existing
  console display quirk, identical with/without JIT).
- Gate: test/lint/bench green; Test262 language 0 regressions, AND the **LJS_JIT=1** language differential
  0 regressions (validates the hand-encoded i64 path over the whole suite).

## Next
- `for(let …; …; …)` still doesn't JIT (per-iteration env / let-head — the bytecode compiler bails);
  spec 125. Then: make the JIT default-on once the LJS_JIT differential is clean across language+built-ins.
