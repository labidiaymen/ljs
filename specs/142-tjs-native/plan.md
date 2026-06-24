# Plan — spec 142 tjsc

## Architecture
`typed-JS source → tjsc (lex → parse → [typecheck] → emit Zig) → zig build-exe → native binary`

- **`src/tjsc.zig`** — self-contained front-end + Zig lowering. No `@import` of the engine; no shared
  state with the interpreter. Own minimal lexer/parser (the JS subset is small; reusing the engine's
  parser would risk the Test262 path and fight its dynamic-JS AST).
- **`src/main.zig`** — `ljs compile <file>` subcommand: read file → `tjsc.compileToZig` → write
  `<base>.zig` → `std.process.spawn(io, {zig build-exe …})` → native `<base>.exe`.

## Cycle 1 design calls
- Integer (`i64`) arithmetic only; precedence via recursive descent (add → mul → unary → primary).
- Emit fully-parenthesized Zig expressions (trivially correct precedence in the output).
- `print(x)` lowers to `std.debug.print("{d}\n", .{x})`.
- `-O ReleaseFast`, `-femit-bin=<base>.exe`; zig's diagnostics inherit our stderr.

## Constitution check
- **Correctness-first:** output is verified by running the produced binary.
- **No-regression:** tjsc is isolated — the engine, interpreter, and Test262 differential are
  untouched. `zig build` / `test` / `lint` / `bench` must stay green.

## Risk
Subprocess + file-write use the Zig 0.16 `Io` API (`std.process.spawn(io,…)`, `Dir.writeFile(io,…)`).
Requires `zig` on PATH at runtime (documented).
