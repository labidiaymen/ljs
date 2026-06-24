# Tasks — spec 142 tjsc

## Cycle 1 — end-to-end skeleton
- [x] `src/tjsc.zig`: lexer (numbers, `+ - * / ( ) ; ,`, idents, `//` comments)
- [x] parser: `console.log(expr);` statements; expr = add → mul → unary → primary (precedence + parens)
- [x] AST + `emitZig` (fully-parenthesized) + `compileToZig(arena, source)`
- [x] `ljs compile <file>` in `src/main.zig`: read → lower → write `.zig` → `zig build-exe` → native exe
- [x] verify: `console.log(1+2*3)` → `demo.exe` prints `7`; `(10-4)*7 → 42`; `100/5+3 → 23`
- [x] gate: `zig build` + `lint` green (Test262 N/A — typed, non-dynamic language)

## Cycle 2 — typed variables + functions
- [x] types `i64`/`f64`/`bool` (TS aliases `int`/`number`/`boolean`); `let name: T = expr;` + var refs
- [x] typed example (`area.tjs`) compiles to native and runs (40/50/22)
- [ ] `function f(a: T, b: T): T { … return … }` + calls
- [ ] per-type `console.log` formatting (bool) + reject cross-type mixing (→ Cycle 3 checker)

## Cycle 3 — control flow + type checker
- [ ] `if/else`, `while`, comparison/logical/`==` ops
- [ ] minimal type checker: infer/check, reject `let x: i64 = "s"` etc.

## Cycle 4 — composite type + benchmark
- [ ] typed array or struct + tiny stdlib
- [ ] compile fibonacci → native; benchmark vs Node + ljs interpreter
