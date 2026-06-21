# Spec 112 — Native JIT (beat Node on compute)

**Status:** In progress — Tier 0 (emitter) + Tier 1 (integer JIT) DONE. Tier 1 beats Node in-engine
on the isolated compute loop: **820 ms vs Node 1208 ms (1.47× faster)**, correct + tested + lint-clean.
**Axis:** Performance (host/runtime). NOT a Test262 conformance change — the JIT is a CLI/host
fast path that must hold language conformance by construction (deopt to the interpreter on anything
it can't compile).

## Why (the validated case)

An interpreter — tree-walk OR bytecode VM — **cannot** beat V8 on pure-JS compute. Measured this
machine, Node 22:

| `sum` loop | Node 22 | ljs tree-walk | ljs bytecode VM | native i64 (ceiling) |
|---|---:|---:|---:|---:|
| 15M iters | 17 ms | 3733 ms (220×) | 618 ms (36×) | — |
| 1e9 iters | 672 ms | ~148 s | ~27 s | **~75 ms (≈9× faster)** |

The only tier that flips compute from a loss to a win is a **native JIT with integer (SMI)
specialization**. Validated end-to-end with a proof-of-concept:

- A hand-emitted x86-64 `sum` loop in RWX memory ran **correct** (`sum(5000)=12497500`) and beat
  Node **1.4×** even as naïve scalar code; the optimized ceiling is **~9×**.
- The critical trick: native **`f64` math LOSES to Node** (~880 ms vs 672 ms); native **`i64`
  with overflow→float guards WINS** (~75 ms). V8 is fast because it runs small integers as SMIs;
  the JIT must do the same or it doesn't beat Node.

ljs already beats Node where the work is native, no JIT needed: **startup** (79 vs 140 ms, 1.8×),
**`crypto.randomBytes`** (87 vs 220 ms/100k, 2.5×). The JIT closes the *compute* gap; native
built-ins close the *formatting* gap (see "What the JIT does NOT cover").

## The tiered roadmap (Ignition → TurboFan, ljs-scale)

The JIT grows in tiers; each lands behind `LJS_JIT` (off by default) and gates on **0 Test262
regressions** + no bench regression. Higher tiers cover more JS but cost more.

- **Tier 0 — x86-64 emitter** *(DONE — `src/jit_x64.zig`)*: a register-only machine-code emitter
  (mov/add/sub/imul/cmp/jcc/jmp/ret + label patching) + RWX `makeExecutable`. Unit-tested: emits a
  `sum` loop and runs it for correct results. This is the codegen backend every tier uses.
- **Tier 1 — integer JIT** *(DONE — `src/jit.zig`)*: compiles the bytecode integer subset to native —
  slots in callee-saved regs, operand stack in caller-saved regs, **32-bit SMI arithmetic with a single
  `jo` overflow guard** (i32 window = f64-exact, V8's SMI window), peepholes that compile `x = x OP v`
  straight onto a slot register, SMI entry guard at the call boundary, deopt-to-tree-walk on
  miss/overflow/`return undefined`. Behind `LJS_JIT` (off by default), independent of the VM.
  **Beats Node 1.47× on the isolated compute loop** (820 vs 1208 ms). *Honest limit:* it JITs only
  the leaf function — call-heavy code (200k calls/loop) is still bounded by the interpreted caller +
  call dispatch (ljs 861 ms vs Node 674 ms), so Node wins there until the caller is JIT'd too (later tier).
- **Tier 2 — float + mixed numerics**: SSE2 `f64` ops, int↔float transitions, `Math.*` intrinsics.
  Covers numeric code that isn't pure small-int.
- **Tier 3 — strings / arrays / typed-arrays**: JIT property reads, array + typed-array indexing,
  string building with type guards. **This is the tier that makes uuid-style formatting code fast**
  (today: ljs 216 ms vs Node 26 ms/100k uuid — all in JS hex formatting on the interpreter).
- **Tier 4 — objects + type feedback (inline caches)**: hidden-class/shape guards, polymorphic
  inline caches, deopt on shape change. The V8-TurboFan-equivalent tier; open-ended.

**Honest scope:** Tiers 0–1 are bounded and validated (beat Node on numeric compute). Tiers 3–4
are where general JS (objects, strings, real packages) gets fast — a multi-stage, V8-class effort.
We commit to 0–1 now; 2–4 are roadmap, each its own spec/cycle.

## What the JIT does NOT cover (and the cheaper alternative)

The integer JIT (Tier 1) won't touch crypto/string/object-heavy code like uuid — those have no
hot integer loop. For *those*, the higher-ROI lever is **native built-ins** (the same path that
already makes `randomBytes` win): e.g. a native hex-encode / native `uuid` would close uuid's 8.3×
gap immediately, without waiting for Tier 3. JIT and native-built-ins are complementary, not rivals.

## In scope (this cycle — Tier 0)
- The x86-64 emitter + RWX execution + a unit test proving correct, executable codegen.

## Out of scope (this cycle)
- Bytecode→native compilation (Tier 1), engine wiring, deopt, SMI marshalling — the next cycle.
- ARM64 / SysV (Linux/macOS) backends — the encoder is portable; add when needed.
- NaN-boxing of `Value` — a later prerequisite for the Tier-1 marshalling fast path.

## Success criteria
- **Tier 0 (this cycle):** `jit_x64.zig` emits x86-64 that executes correctly from RWX memory,
  proven by a unit test (`sum(5000)=12497500`, `sum(0)=0`, `sum(10)=45`); `zig build test` +
  `zig build lint` green; **zero** impact on the default build (the emitter is only called by tests).
- **Tier 1 (next):** a `sum`-shaped JS function runs JIT'd in-engine under `LJS_JIT=1`, beats Node
  on the 1e9-iter loop, with **0 Test262 regressions** (JIT off by default) and no bench regression.
