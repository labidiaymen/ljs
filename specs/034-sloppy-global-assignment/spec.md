# M34 — Sloppy assignment to an unresolved name creates a global; runtime strict-mode + lexical TDZ hoisting (§9.1.1.4.16 / §6.2.5.6 / §13.x)

## Goal
Implement §6.2.5.6 PutValue step 6 for an **unresolved** IdentifierReference:

- **Sloppy mode:** `x = v` where `x` is not declared SUCCEEDS, creating a configurable property on
  the global object (and a global binding) — it does NOT throw `ReferenceError`.
- **Strict mode:** the same assignment throws `ReferenceError` (unchanged).

This retires the staged M1 cut where an unresolved assignment threw `ReferenceError` in *every*
mode. It required two supporting pieces the engine lacked:

1. **Runtime strict-mode tracking.** Strictness was known only at parse time. M34 threads it to
   runtime so the assignment site can gate sloppy-vs-strict.
2. **Lexical TDZ hoisting.** Without `let`/`const`/`class` hoisting, a name declared *later* in a
   scope was "unresolved" at an earlier assignment — so the new sloppy-global path would wrongly
   create a global instead of a §13.x Temporal-Dead-Zone `ReferenceError`. M34 pre-declares lexical
   names as uninitialized at scope entry so a forward reference is a proper TDZ error.

## Rules implemented

### 1. Unresolved PutValue (§6.2.5.6 / §9.1.1.4.16)
- Sloppy: `Set(globalObject, name, value, false)` — when absent, creates a `{writable, enumerable,
  configurable}` own property. Written to BOTH the reified global object (`globalThis.x`) and the
  global declarative Environment (bare `x`) to keep the two views consistent at creation.
- Strict: `ReferenceError`. A direct `eval` inherits the caller's strictness (§19.2.1.1); an
  indirect `eval` runs sloppy in the global context (unless its own `"use strict"`).
- Only the SLOW (unresolved) assignment path consults strictness — a resolved binding's mutation is
  unchanged (hot path untouched; the bench confirms no regression).

### 2. Runtime strict-mode flag
- `ast.Program.strict` and `ast.Function.strict` carry the parse-time strictness (inherited strict,
  an own `"use strict"` prologue, a class member — always strict, or a class constructor — always
  strict). `object.FunctionData.strict` mirrors it onto the function object.
- The interpreter has a runtime `strict` field: set from the Program on `run` (saved/restored so an
  eval body's strictness doesn't leak), and saved/restored to `FunctionData.strict` around every
  function/generator/async body. So a sloppy callee invoked from strict code (and vice-versa) is
  gated by ITS OWN lexical strictness, not the caller's.

### 3. Lexical TDZ hoisting (§14.2.3 / §10.2.11 / §16.1.7, lexical step)
- Before a scope's statements run (Script/eval body, function body, and a block that has its own
  scope), every top-level `let`/`const`/`class` BoundName is created in the env as UNINITIALIZED
  (its TDZ). The declaration statement initializes it when reached.
- The identifier ASSIGNMENT, READ, and `++`/`--` paths now throw `ReferenceError` on an
  uninitialized binding (TDZ). `var` and function declarations are not lexical (function
  declarations are created initialized; `var` is a documented separate cut).
- Hot-path safe: declaration-free blocks reuse the parent env and never reach the hoist pass.

### 4. `delete` of a sloppy-created global (§13.5.1.2 / §9.1.1.4.18)
- `delete x` for an identifier removes a CONFIGURABLE global-object property (and its mirrored
  Environment binding) — so `x = 1; delete x; x` throws on the final read. Non-configurable / absent
  → the prior M-subset deviation (return `true` without removing) is preserved.

## Out of scope (unchanged M-subset cuts)
- `var` / function-declaration hoisting (only LEXICAL names are hoisted here).
- Full bidirectional global-object↔Environment sync after creation (e.g. `var x` does not mirror to
  `globalThis.x`); M34 only guarantees consistency at sloppy-global *creation* time.

## Verification
- `x = 5; x` → 5; `x = 5; globalThis.x` → 5; `r = 8; globalThis.r` → 8 (sloppy creates the global).
- `"use strict"; y = 5;` → ReferenceError; strict IIFE / class method assigning an unresolved name →
  ReferenceError.
- `let p; (assign p before the `let`)` → TDZ ReferenceError (not a global). Read / `++` before a
  `let` → TDZ.
- `dx = 1; delete dx; dx` → ReferenceError.
- Full `language/`: passed 37143 → 37292 (85.1% → 85.4%), 0 regressions vs baseline; bench perf ok.
