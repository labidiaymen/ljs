# Spec 109 — perf: interpreter operator fast paths (the "beat Node" track)

Status: In progress (ongoing perf track) · Owner: Aymen

## Why
A Node-vs-ljs package benchmark showed ljs (tree-walk, no JIT) is competitive on native-backed work
(crypto/random) but far behind on pure-JS compute (string ops ~14×, regex ~147×) and meaningfully
behind on arithmetic loops. Beating Node on pure JS ultimately needs a **bytecode VM** (a future epic);
until then this track lands safe, measured, correctness-preserving fast paths on the hot interpreter
operators. Tracked against `bench/baseline.json` (ljs-vs-self) every cycle; `language/` 0 regressions.

## Iteration 1 — binary-operator primitive fast paths (`interp_ops.zig`)
The `+`, numeric (`-*/% `bitops), and relational (`< > <= >=`) operators ran the full Completion-wrapped
`ToPrimitive` machinery even when both operands are already primitives. ToPrimitive is **identity** on a
primitive (no observable side effect), so:
- `add`: two numbers → direct `l + r`; two strings → direct concat (skip ToPrimitive/ToString).
- `numericBinary`: two numbers → skip both ToPrimitive calls + Symbol checks, go straight to the op.
- `relationalV`: two numbers → the numeric comparison directly.
**Measured:** loop_mix −12.6%, loop_sum −7.5% vs baseline; str_build ~flat (it is allocation-bound — the
next target). build/test/lint green; `language/` exit 0 (0 regressions, 95.1%).

## Next targets (later iterations)
- String building is O(n²) (`s = s + x` reallocates) — a cons/rope string or a builder fast path.
- Variable resolution is a per-access string-hashmap walk up the scope chain — scope-slot resolution /
  inline caching.
- Regex engine (the 147× gap) — the single biggest pure-JS gap.
- The strategic answer: a bytecode compiler + VM (replace tree-walk on the hot path).
