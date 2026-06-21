# Design — ljs bytecode VM (the "Ignition" tier): replace tree-walk on the hot path

Status: **In progress** — Phase 0 core landed (isolated + tested); integration next · Owner: Aymen

## Progress log
- **Phase 0a (done):** the VM core, isolated + unit-tested, NOT yet wired into the engine (zero impact
  on behavior/bench/conformance by construction). `src/bytecode.zig` (Chunk + Op set), `src/vm.zig`
  (the `while/switch` dispatch loop — delegates every operator/property/call to the existing runtime
  helpers), `src/compiler.zig` (AST→bytecode for the Phase 0 subset + 4 end-to-end tests that parse →
  compile → run on the VM and check results: arithmetic, while-loop sum `f(100)=4950`, for+if+compound
  `=20`, conditional+logical). Slots = locals (no hashmap walks). `compile()` returns null (→ tree-walk)
  for anything outside the subset.
- **Phase 0b (next):** wire into `interp_expr.callFunction` behind `LJS_VM` (compile a simple function
  lazily on first call, cache the `*Chunk`, run on the VM; else tree-walk). Then run the FULL Test262
  with `LJS_VM=1` as a differential check (must hold 95.1%), and a microbench (VM vs tree-walk on a
  compute loop) to confirm the speedup. Add `++`/`--` (a value-discarding `inc_slot`/`dec_slot`).

## 1. Problem & goal
ljs evaluates the AST directly (tree-walk): every operation is a recursive Zig call returning a
`Completion`, locals resolve via string-keyed hashmap walks, and `Value` is a ~24-byte union. The
Node(V8) benchmark showed 3–100× gaps on pure JS — V8 runs *compiled bytecode + JITed machine code*;
ljs runs the AST. **Goal:** add V8's *first* missing tier — a **bytecode compiler + a tight VM dispatch
loop** — to get an estimated **3–6×** on compute-heavy code (and unlock inline caches / NaN-boxing
afterwards), WITHOUT regressing the 95.1% language conformance.

Non-goals (separate, later): a native JIT (TurboFan tier — not worth it); NaN-boxing; hidden classes
(they layer on *after* the VM exists). This doc is the Ignition-equivalent only.

## 2. The one idea that de-risks everything: reuse the runtime, replace only the dispatch
The VM is a **new driver over the EXISTING semantics**, not a reimplementation. Each opcode calls the
SAME runtime helpers the tree-walk already uses and trusts:
`interp_ops.applyNumericOrStringOp`, `relationalV`, `getProperty`/`setProperty`, `callFunction`,
`toBooleanV`, `Object.create`, etc. So the observable behavior is unchanged by construction — only
*how we get from one operation to the next* changes (a flat instruction stream + a `while` loop instead
of recursive AST descent). This is what keeps Test262 at 95.1% while we swap the engine underneath.

## 3. Incremental adoption with FALLBACK (the safety net)
`compile(fn_ast) ?*Chunk` returns null for any construct the VM doesn't handle yet → that function runs
on the **existing tree-walk** unchanged. So:
- The two engines coexist; we grow VM coverage construct-by-construct.
- Every phase is shippable and measurable; nothing is "all or nothing."
- A hidden flag `LJS_VM=0` disables the VM globally (instant rollback).
- **Differential testing:** run Test262 with VM ON and compare to the tree-walk baseline every phase —
  any divergence is a bug to fix before merging. Conformance must stay exactly 95.1%.

## 4. VM shape (decisions)
- **Stack-based bytecode** for the MVP (operand stack + local slots). Simpler + correct-first than a
  register VM; still eliminates the per-node Zig call overhead (the dominant tree-walk cost). A
  register rewrite (Lua/Ignition style, ~30% fewer ops) is a *later* optimization once it's correct.
- **Operands stay `Value`** (the existing 24-byte union) at first — the VM stack is `[]Value`. NaN-boxing
  is a separate follow-up so we don't change value semantics and the VM at the same time.
- **Dispatch:** a `while (true) switch (op)` loop (portable, simple). Computed-goto / tail-call threading
  is a later micro-opt if the switch shows up in profiles.
- **Frames:** a `CallFrame { chunk, ip, slots_base, ... }`; the VM recurses into `run(frame)` per JS
  call initially (Zig stack = JS call stack). An explicit frame stack (to survive deep JS recursion and
  to enable stackless generators) is a Phase-5 upgrade.
- **Locals = stack slots.** The compiler's resolver assigns each local a slot index; access becomes an
  array index, not a hashmap walk — this folds in the **scope-slot optimization (#2)** for free.
  Free variables (closures) become **upvalues** captured into the closure object. Globals: by name
  (later: a global slot cache / IC).

## 5. Chunk & instruction set (starter)
```
Chunk = { code: []u8, consts: []Value, n_slots: u16, upvalues: []UpvalueDesc, src_map: ... }
```
A first opcode set (grows per phase). `[k]`=const index, `[s]`=slot, `[j]`=jump offset, `[n]`=count.
```
CONST [k]            push consts[k]
LOAD_SLOT [s]        push slot[s]            STORE_SLOT [s]     slot[s] = pop
LOAD_UPVAL [u]       push upvalue[u]         STORE_UPVAL [u]
LOAD_GLOBAL [k]      STORE_GLOBAL [k]        DEFINE_GLOBAL [k]
POP / DUP / SWAP
ADD SUB MUL DIV MOD EXP                       (→ interp_ops fast paths + slow fallback)
LT GT LE GE EQ NE SEQ SNE                     BIT_AND BIT_OR ... SHL SHR
NEG NOT TYPEOF                                TO_BOOLEAN
JUMP [j]   JUMP_IF_FALSE [j]   JUMP_IF_TRUE [j]   (control flow / &&,||,?:)
GET_PROP [k]  SET_PROP [k]  GET_INDEX  SET_INDEX  (→ getProperty/setProperty; IC slot reserved)
NEW_OBJECT  NEW_ARRAY [n]  NEW_CLOSURE [k]
CALL [n]   CALL_METHOD [n]   NEW [n]   RETURN
THROW   ENTER_TRY [handler]   LEAVE_TRY            (exception handler table)
```
Compound assignment, `for`, `while`, `switch`, destructuring, spread → lowered to these by the compiler.

## 6. Phasing (each phase: compile→run→differential-test→bench→commit)
- **Phase 0 — skeleton.** `Chunk`, opcodes, the VM loop, `compile()` with the fallback hook, constant
  pool. Compile only: numeric/string literals + arithmetic + `var` locals + the comparison ops. Target:
  the bench cases `loop_sum`/`loop_mix`/`str_build` compile and run on the VM. **First measurable win.**
- **Phase 1 — control flow + locals.** `if/else`, `while`, `for`, `break`/`continue`, logical/ternary,
  block scoping (slot lifetimes). Most loops now VM-native.
- **Phase 2 — functions.** declarations/expressions/arrows, params, `return`, calls, recursion,
  closures (upvalue capture), `this`/`new.target`.
- **Phase 3 — objects.** object/array literals, property get/set, index access, method calls, `new`.
  **Add inline caches here** (per-site shape→offset cache) — the property-access win.
- **Phase 4 — exceptions & the rest.** `try/catch/finally`, `switch`, `typeof`/`instanceof`/`in`,
  template literals, optional chaining, destructuring, spread/rest.
- **Phase 5 — the hard tail.** generators/async (either stackless VM frames, or KEEP them on the
  tree-walk via fallback — recommended first), `with`/`eval` (keep on tree-walk — rare + hostile to
  slot resolution).
- **Phase 6 — optimize.** inline caches everywhere, NaN-boxed `Value` (8 bytes, SMIs), peephole +
  constant folding in the compiler, maybe a register-VM rewrite.

## 7. Where it plugs in
- New files: `src/bytecode.zig` (Chunk/opcodes), `src/compiler.zig` (AST→bytecode), `src/vm.zig` (the
  loop). The compiler reuses the existing `ast.zig`; the VM reuses `interp_ops`/`interp_property`/
  `interpreter.callFunction` etc.
- `callFunction` becomes a dispatcher: if the callee has a compiled `Chunk` → `vm.run`; else → the
  current tree-walk body. (Closures store an optional `*Chunk`.)
- Generators/async/`with`/`eval` functions simply never get a `Chunk` (compile returns null) → tree-walk.

## 8. Expected payoff & cost
- **Perf:** Phase 0–1 alone ~**2–4×** on arithmetic/loop code (no per-node calls, slot locals). Phase 3
  + inline caches: property-heavy code multiples faster. Realistic end state ~**2–4× of V8** on pure JS
  (vs 3–100× today) — *without* a JIT.
- **Effort:** Phase 0–3 (covers the majority of hot code) ≈ a few focused weeks; the full thing
  (incl. async/generators on the VM) is multi-month. The fallback means **wins land early** (bench
  improves the moment Phase 0 merges) and risk stays bounded.
- **Risk:** correctness — mitigated by (a) reusing runtime helpers, (b) differential Test262, (c) the
  fallback + kill-switch. Two execution paths during the transition is the real maintenance cost.

## 9. Recommendation
Worthwhile IF the goal is genuinely closing the pure-JS gap (it's the only thing that does). Sequence it
AFTER the cheap self-contained wins already queued in the perf loop (regex NFA, rope strings), so those
land independently of this epic. Start at **Phase 0** behind `LJS_VM` with differential testing from
commit one.
