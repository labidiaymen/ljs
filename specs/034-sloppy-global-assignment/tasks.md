# M34 — Tasks

- [x] T1 — Carry parse-time strictness onto the AST: `ast.Program.strict` and `ast.Function.strict`
      (set at every Function creation site in `parser.zig`: function decl/expr, arrow, class/object
      methods + accessors; class members are always strict). `parseMethodBody` returns the body
      strictness via an out-param (its `self.strict` is restored on exit).
- [x] T2 — Mirror strictness on the function object: `object.FunctionData.strict`, populated by
      `evalFunctionExpr`, the `func_decl` path, and the synthesized class constructor (always strict).
- [x] T3 — Runtime strict-mode flag on the interpreter: set from `Program.strict` in `run`
      (saved/restored), and saved/restored to `FunctionData.strict` around every function body
      (`callFunction`) and generator/async body (`runGeneratorBody`).
- [x] T4 — Direct `eval` inherits the caller's strictness; indirect `eval` is sloppy
      (`performEval` parses with the inherited flag; §19.2.1.1).
- [x] T5 — `assignUnresolved`: in sloppy mode create the global on BOTH the reified global object and
      the global Environment; in strict mode throw ReferenceError. Wired into the `.assign` and
      `assignToTarget` identifier paths (incl. the `with` `.unresolved` case).
- [x] T6 — Lexical TDZ hoisting: `hoistLexicalNames` / `hoistPatternNames` pre-declare top-level
      `let`/`const`/`class` BoundNames as uninitialized at Script/eval body, function body, generator/
      async body, and own-scope block entry. Add `!initialized` TDZ checks to the identifier assign,
      and `++`/`--` paths (read + logical-assign already checked).
- [x] T7 — `delete identifier` removes a configurable sloppy-created global (object property +
      Environment binding); non-configurable/absent keeps the prior deviation.
- [x] T8 — Tests in `src/engine.zig`: sloppy creates global (+ globalThis reflection + enumerable),
      strict throws (script/IIFE/class method), TDZ before-decl (assign/dstr/read/`++`), `delete`.
- [x] T9 — Gates: `zig build`, `zig build test` (0), `zig build lint` (0/0), full `language/`
      ≥ 37143 with 0 regressions vs baseline (got 37292 / 85.4%), `zig build bench` perf ok.
      Update `baseline/language.json`.
