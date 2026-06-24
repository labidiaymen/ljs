# Spec 142 — tjsc: Typed-JS → Zig → native compiler (POC, 4 cycles)

**Status:** Cycle 1 Done · Cycles 2–4 planned

## Why
ljs (the from-scratch engine) is a tree-walk interpreter — it cannot turn a `.js`/`.ts` file into a
native binary, and dynamic JS fundamentally can't (it needs a runtime/GC). A *statically-typed* JS
subset CAN: with types known at compile time you get predictable layout and efficient native code
(the Static Hermes / AssemblyScript model). This POC proves it by lowering a typed-JS subset to **Zig
source** and letting `zig build-exe` (LLVM) produce the native binary — so we only write the
front-end + lowering; optimization/codegen/cross-compile come free.

This is a SEPARATE tool (`tjsc`, `ljs compile <file>`), not part of the ECMAScript engine. It never
touches the interpreter or the Test262 path → zero conformance risk.

## Scope (the 4-cycle POC)
- **Cycle 1 (this):** end-to-end skeleton — integer arithmetic + `print(expr);` → native binary.
- **Cycle 2:** typed `let` variables (`i64`/`f64`/`bool`) + typed functions + calls.
- **Cycle 3:** control flow (`if`/`while`) + comparisons + a minimal **type checker** (rejects mismatches).
- **Cycle 4:** one composite type (typed array or struct) + tiny stdlib; compile **fibonacci** to
  native and **benchmark** vs Node and the ljs interpreter.

## Out of scope
Dynamic JS semantics (prototypes, `any`, `eval`), GC, the npm ecosystem, full TS type system. This is
a typed *subset* that looks like JS — not a JS replacement.

## Cycle 1 acceptance (met)
- Given `print(1 + 2 * 3);` When `ljs compile demo.tjs` Then a native `demo.exe` prints `7`.
- Operator precedence + parens + unary minus lower correctly (`(10-4)*7 → 42`, `100/5+3 → 23`).
- The Test262 differential is unchanged (tjsc is isolated from the engine).

## Success criteria
A native executable produced from typed-JS source, with the interpreter/conformance path untouched.
