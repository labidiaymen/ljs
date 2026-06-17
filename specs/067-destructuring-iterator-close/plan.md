# Plan: array-destructuring IteratorClose (M79 / 067)

## Approach
Add `destrCloseChecked(self, rec: ArrayDestr) EvalError!Completion` next to `destrClose` (~4286):
`.fast` → `.normal`; `.iter` not-done → `self.iteratorCloseChecked(it.iterator)` (reuses M78's
helper); done → `.normal`.

Replace the two NORMAL-completion close sites:
- `bindPattern` array case (~2989, "pattern satisfied with no rest"): `const cc = try
  self.destrCloseChecked(rec); if (cc.isAbrupt()) return cc;`
- `assignPattern` array case (~3102): same.

All other `destrClose(rec)` calls (engine error / abrupt default / throwing sub-pattern / throwing
target — sites ~2954/2958/2969/2973/3093/3097) stay the void swallowing `destrClose` (§7.4.11 step 4).

## Files touched
`src/interpreter.zig` (`destrCloseChecked` + the two normal-completion sites).

## Risks
LOW. Only the previously-swallowed normal-completion error path changes; abrupt sites unchanged
(regression guard 1). Conformance gate + guards cover it.

## Constitution Check
Correctness leads (§8.5.2/§13.15.5.3/§7.4.11) ✔; perf: destructuring-close only, not hot ✔.
