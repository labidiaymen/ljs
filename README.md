# Lumen Native Compiler

This branch is now focused on a compiled TypeScript-syntax language:

```text
TypeScript source (.ts) -> compiler -> generated Zig -> native binary
```

The existing `src/lumen_compiler.zig` prototype is the seed. It already proves
the useful path: TypeScript-syntax source can be lowered to Zig source and then
compiled with `zig build-exe` into a small native executable. From here, the
project should evolve away from JavaScript engine conformance and toward the
Lumen language spec.

## Scope

V1 is not a JavaScript runtime and not a Test262 project. The source language
uses TypeScript syntax, but with compiled static semantics:

- `.ts` source files
- fixed static types with local inference
- `number`/`float`/`f64` for floating-point, `int`/`i32` for 32-bit integers
- numeric literals: decimal, float (`3.14`, `1.5e2`), and `0x`/`0o`/`0b` with
  `_` separators
- `//` line and `/* ... */` block comments
- `===`/`!==` accepted (equivalent to `==`/`!=` under static typing)
- `for...of` over arrays and strings
- `enum` (numeric and string), `interface` (object-type synonym)
- bitwise `& | ^ ~ << >>` and exponent `**` operators (integers)
- nullable types (`T | null`, `T | undefined`), optional `?` fields/params,
  `??` nullish coalescing, `?.` optional chaining, `if (x != null)` narrowing
- numeric literal unions (`type Code = 200 | 404`), array/object destructuring
  (`let [a, b] = …`, `let { x, y } = …`), template literals (`` `hi ${name}` ``)
- no prototypes, `eval`, CommonJS, package.json resolution, or dynamic object
  mutation
- native binary output through generated Zig
- Node-like standard-library surface by explicit wrapper APIs, not full Node
  compatibility

The generated Zig is an implementation artifact. Users should think in the
TypeScript-syntax source language, not in Zig.

## Current Implementation Seed

The current branch contains:

- `src/lumen_compiler.zig`: prototype compiler/lowerer
- `src/lumen.zig`: compiler CLI entrypoint with `lumen compile <file.ts>`
- `specs/001-typescript-to-zig-native`: clean Spec Kit track for the new product

The old ljs/Test262 specs were removed from this branch so the active design does
not drift back toward ECMAScript conformance.

The repository still contains the legacy JavaScript lexer/parser/AST used by the
old engine path. Lumen keeps separate compiler modules because V1 intentionally
removes JavaScript dynamism rather than inheriting it.

## Quick Start

Requires Zig 0.16.0.

```sh
zig build
zig build run -- compile specs/001-typescript-to-zig-native/examples/valid/hello.ts
zig build conformance
```

The default build now installs the compiler-first `lumen` executable. The
immediate implementation goal is to align `src/lumen_compiler.zig` with the new
spec: type-check the V1 subset, lower to generated Zig, and produce a native
binary.

`zig build conformance` runs the manifest-driven V1 conformance suite from
`specs/001-typescript-to-zig-native/conformance/manifest.json`, compiling valid
cases, running native binaries, comparing output, and checking invalid
diagnostics.

For a larger robustness and performance comparison against Node.js, run:

```sh
node benchmarks/robustness/run.js
```

## Development

Spec Kit remains the workflow, but the active specs now describe the native
compiler product rather than the legacy JavaScript engine.

Start with:

```text
specs/001-typescript-to-zig-native/spec.md
specs/001-typescript-to-zig-native/plan.md
specs/001-typescript-to-zig-native/tasks.md
```
