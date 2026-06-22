# Spec 123 — JIT idiomatic for-loops: `i++`/`i--` in the bytecode compiler

**Status:** Done (2026-06-22). First cycle of the JIT epic (`/loop until ljs beats Node`, repointed to
the JIT). Idiomatic `for (…; …; i++)` loops now compile to bytecode → native, hitting Node-class speed.

## Why
The x86-64 JIT (spec 112) already compiles loops to native and reaches Node parity WHEN it engages —
measured: `for(var i=0;i<5e6;i=i+1){…}` ran 88ms under `LJS_JIT` vs Node 83ms (and 28,310ms tree-walked).
But idiomatic code uses `i++`, and the **bytecode compiler bailed on `.update`** (`compiler.zig` →
`fail()`), so almost no real loop reached the JIT. (Separately, the JIT deopts on i32 overflow — the
next cycle, spec 124.)

## Fix
`compiler.zig` `.update` (UpdateExpression on a slot-backed identifier): emit `load_slot; pos
(ToNumber); [dup;] const 1; add|sub; store_slot`, leaving the NEW value for prefix `++i` / the OLD
number for postfix `i++`. `.pos` is ToNumber semantics for the VM and a no-op for the JIT's SMIs, so the
sequence is JIT-compilable. A non-slot (global) counter still bails to the tree-walk.

## Result
- `for(…;…;i++){ x=(x+7)&1023 }` ×5M: **24,640ms → 120ms** under `LJS_JIT` (~200×; Node 83ms).
- Update semantics correct (`i++ ++i i-- --i`, `a[j++]`) under tree-walk, VM, and JIT — match Node.
- 0 Test262 regressions (the VM/JIT are opt-in; default path unchanged); `zig build bench` no regression.

## Next (spec 124)
Widen the JIT's SMI arithmetic from i32 to i64 (deopt past 2^53) so accumulators (`sum += i`) stop
deopting on i32 overflow — the other half of making real numeric code JIT.
