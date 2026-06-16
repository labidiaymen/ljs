# M15 — `eval` (direct + indirect)

ECMA-262 §19.2.1 `eval(x)` + §19.2.1.1 PerformEval. Tree-walk interpreter.

## Goal
`eval` is the single biggest remaining language lever: ~936 of the ~12.5k failing
`language/` files call `eval(`. Implement the global `eval` function (and
`globalThis.eval`), supporting both direct and indirect eval.

## Semantics

### `eval(x)` core (§19.2.1)
- If `x` is not a String → return `x` unchanged.
- Parse the string as a Script. A parse error → throw a real `SyntaxError`.
- The completion VALUE of the script is `eval`'s return value (the engine's `run`
  already returns the last statement's value):
  - `eval("1+2")` → 3
  - `eval("var x=5")` → undefined
  - `eval("if(true) 7")` → 7
  - `eval("1;2;3")` → 3
  - `eval("({x:1}).x")` → 1

### Direct vs indirect (§19.2.1.1 PerformEval)
- **Direct eval** = a CallExpression whose callee is *exactly* the
  IdentifierReference `eval` that resolves to the intrinsic %eval%. Detected at the
  call site (`evalCall`): if the callee node is `identifier "eval"` AND the resolved
  binding's value is the intrinsic eval function object → DIRECT eval.
  - Runs in the CALLER's running execution context: reads/writes surrounding lexical
    bindings. Implemented by running the parsed program in a fresh CHILD Environment
    of the caller's current env (so reads/writes of outer bindings work, and
    `let`/`const`/`class` are eval-local).
  - `var`/function declarations: declared into the child eval env in this slice
    (documented approximation — precise hoisting into the surrounding function/global
    VariableEnvironment is deferred; see Deferred).
  - `this` and the surrounding `this_val` / `home_object` are inherited (we run with
    the interpreter's current `this_val` unchanged).
  - Strictness: if the surrounding code is strict OR the eval string has a
    `"use strict"` prologue, the eval body parses strict. (Detected by the parser's
    own directive-prologue check; the caller's strictness is propagated via the
    parse mode — see Deferred for the precise caller-strictness propagation.)
- **Indirect eval** = `eval` called any other way (`(0, eval)(s)`, `var e=eval; e(s)`,
  `globalThis.eval(s)`). Runs the code in the GLOBAL environment with global `this`.

### Limits
- Step/recursion counters (`steps`/`step_limit`, `depth`/`max_depth`) are the
  interpreter's existing live counters — eval reuses them (NOT reset), so runaway eval
  code still terminates and recursion through eval is bounded.

## Design
- New `NativeId.eval_fn`. The `eval` global is a native function object so the harness
  and `globalThis.eval` both see it. It is installed by `builtins.setup`.
- `callNative` handles `.eval_fn` as the INDIRECT path (global env, global this).
- `evalCall` detects the direct case BEFORE dispatching: when the callee is
  `identifier "eval"` resolving to the %eval% intrinsic, it calls a dedicated
  `performEval(source, env, direct=true)` with the caller's current env.
- `performEval` factors the parse+run: parse (SyntaxError on failure), create the
  target env (child of caller for direct, global for indirect), and `run` the program
  on the SAME interpreter (preserving counters, this_val).

## Tests (src/engine.zig)
- `eval("1+2")` → 3
- `eval("var x=10; x*2")` → 20
- `eval(42)` → 42 (non-string passthrough)
- direct reads locals: `function f(){ var a=5; return eval("a+1") } f()` → 6
- direct writes: `function f(){ var a=1; eval("a=9"); return a } f()` → 9
- indirect is global: `var e=eval; function f(){ var a=1; try{ e("a"); return "no" }catch(x){ return "ref" } } f()` → "ref"
- `eval("({x:1}).x")` → 1
- `eval("1;2;3")` → 3
- SyntaxError: `try{ eval("var") }catch(e){ e.name }` → "SyntaxError"

## Deferred (documented edge cases)
- Precise `var`/function hoisting into the surrounding function/global
  VariableEnvironment (we declare into the eval-local child env). Tests that assert a
  `var` declared in a direct eval is visible to the *surrounding* function after the
  eval may still fail.
- Precise propagation of the *caller's* strict mode into the eval parse when there is
  no explicit `"use strict"` in the eval string (we parse the eval string sloppy unless
  it carries its own directive). The common harness-driven tests use explicit
  directives or test sloppy behavior.
- `eval` is not yet a constructor-rejecting / non-`new`-able distinction beyond the
  generic native call path.
