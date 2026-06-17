# Implementation Plan: `var` hoisting (M71 / 059)

## Approach

Model the §10.2.11 *VariableEnvironment* explicitly and route every `var` write to it, plus a
deep pre-execution pass that instantiates the VarDeclaredNames.

### 1. Environment (`src/environment.zig`)
- Add field `is_var_scope: bool = false`.
- Add `varScope(self) *Environment`: walk parents to the nearest `is_var_scope` (the global env
  is always a var scope, so the walk terminates).

### 2. Mark the VariableEnvironments
Set `is_var_scope = true` on:
- the global/script env (where it is created — `engine.zig` / builtins global env),
- the function `call_env` (`interpreter.zig:~2507`),
- the generator/async `call_env` (`interpreter.zig:~4232`),
- strict direct-eval env; sloppy direct eval does NOT introduce a var scope (its `var`s escape
  to the caller's var scope) — leave that env non-var-scope so `varScope()` climbs past it.

### 3. Var-hoisting pass (`src/interpreter.zig`)
- `hoistVarNames(stmts, scope)` mirroring the parser's `collectVarNames` traversal (descend into
  block/if/while/do/for/for-in/for-of/try/with/switch/labeled bodies; STOP at function/class
  boundaries; collect for-head `var`s; ignore func decls and let/const). For each BoundName,
  `scope.declare(name, .undefined, true, true)` **iff** `scope.lookupLocal(name) == null`
  (no-clobber).
- Call it right after the existing `hoistLexicalNames(body, scope)` at the three *scope* sites:
  script (`run`, ~204), function body (~2617), generator/async (~4296). NOT at block sites.

### 4. Route `var` writes to the var scope
- `.declaration` case (~261): when `d.kind == .var_decl`, target `env.varScope()`. Identifier
  with no initializer → skip (hoist already created it). Identifier with initializer → set the
  existing binding's value (or declare if somehow absent). Pattern (always has an initializer per
  the parser) → `bindPattern` into the var scope.
- `bindForHead` (~741): for a `var` head, bind the item into `env.varScope()` but return
  `.env = env` (body runs in the loop env, not the var scope) — preserving lexical resolution for
  any sibling `let`/closures.

## Files touched
- `src/environment.zig` — flag + `varScope()`.
- `src/interpreter.zig` — mark var scopes; `hoistVarNames`/`hoistVarNamesStmt`; `.declaration`
  var path; `bindForHead` var path.
- `src/engine.zig` — mark the global env `is_var_scope` (if created there).

## Risks
- **Perf hot path (the perf gate).** Each function call now runs a deep `hoistVarNames` walk.
  Mitigation: the walk is O(statements) once per call (amortized over loop iterations), allocates
  nothing for var-free bodies, and the no-clobber `lookupLocal` is a single hash probe per name.
  Gate with `zig build bench`; if it regresses, precompute a "has vars" bit or cache names on
  `FunctionData`.
- **Regression surface.** Changing `var` semantics touches every function. Mitigation: the
  conformance gate (0 regressions vs baseline) plus targeted local repros for each acceptance
  scenario before the full gate. Watch eval (sloppy vs strict) and the global-script path.

## Constitution Check
- *Correctness leads*: this fixes a documented spec-conformance defect (§10.2.11). ✔
- *Performance measured*: `zig build bench` is a hard pre-commit gate; no ljs-vs-self regression
  permitted. ✔
- *Spec traceability*: clauses cited inline at each change. ✔
