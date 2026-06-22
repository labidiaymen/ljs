# Spec 121 — `for (let …)` per-iteration binding (§14.7.4 CreatePerIterationEnvironment)

**Status:** Done (2026-06-22). A C-style `for` loop with a lexical (`let`/`const`) head now gives each
iteration its OWN binding environment, so a closure created in iteration N captures that iteration's
value: `for(let i=0;i<3;i++){ a.push(()=>i) }` → `0,1,2` (was `3,3,3`). 0 Test262 regressions.

## Problem
`runForBody` ran every iteration in the SAME `loop_env`, so all closures shared the one `i` and saw
its final value. This broke the classic deferred-callback idiom — and affected arrows AND function
declarations equally (it was the loop env, not the fn-decl fix from spec 120).

## Fix (interp_stmt)
- `createPerIterationEnvironment`: a fresh declarative env (sibling under the loop's outer scope) that
  COPIES each loop-head binding's current value; installed before the first iteration and again before
  each update (§14.7.4.2 / .4.4).
- **Perf guard (critical):** always copying made a closure-free `let` loop ~2.5× slower than the `var`
  equivalent (1942ms vs 790ms for 5M iters). A per-iteration env is only OBSERVABLE if the body
  creates a closure, so `mayCreateClosure` statically scans the body once; the copy is skipped for
  provably closure-free bodies (conservative — defaults to "yes" for functions/classes/object literals/
  unrecognized nodes). Result: closure-free `let` loop back to `var` speed (847ms ≈ 849ms), closure
  loops correct.

## Acceptance (verified)
- `for(let i){ a.push(()=>i) }` and `{ function f(){return i} }` → `0,1,2` (match Node).
- Closure-free `let` loop perf == `var` loop perf (no regression).
- `zig build test`/`lint`/`bench` green; Test262 language 0 regressions.

## Note (out of scope)
ljs compute loops remain ~100× slower than Node (tree-walk vs V8 JIT); the native JIT (spec 112) does
not yet compile loops. Closing that is a separate JIT epic.
