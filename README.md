# ljs

A JavaScript engine written from scratch in [Zig](https://ziglang.org) — in the spirit of V8,
but built **spec-first** and optimized for correctness, spec-traceability, and a measured
performance story from day one.

> **Status: early M0.** A tree-walking interpreter evaluates a trivial expression subset
> end-to-end; the Test262 conformance harness and the bytecode/JIT tiers are not built yet.
> This is a learning-grade, in-progress engine, not a drop-in Node replacement.

## Why another engine?

Two ideas drive the project:

1. **The spec is the source of truth.** Every operation maps to an [ECMA-262](https://tc39.es/ecma262/)
   clause, and conformance is judged by the official [Test262](https://github.com/tc39/test262)
   suite — not by intuition. See the [constitution](.specify/memory/constitution.md).
2. **Performance is measured, not deferred.** ljs is benchmarked against Node.js (V8) from the
   first runnable build, with an ljs-vs-self no-regression gate. The data — not dogma — decides
   when to graduate from tree-walk to a bytecode VM.

It's built with **Spec-Driven Development** ([GitHub Spec Kit](https://github.com/github/spec-kit)):
the full specification, plan, and task breakdown live in [`specs/`](specs/001-test262-harness/).

## Quick start

Requires **Zig 0.16.0**. Node.js and [ZLint](https://github.com/DonIsaac/zlint) are optional.

```sh
zig build                       # build the `ljs` executable
zig build run -- eval "1 + 2"   # => 3
zig build run -- eval "2 * (3 + 4)"   # => 14

zig build test                  # run unit tests
zig build fmt-check             # verify formatting
zig build lint                  # zig fmt --check + ZLint (if installed)
```

The CLI (see [contracts/cli.md](specs/001-test262-harness/contracts/cli.md)):

```sh
ljs eval "<source>"   # evaluate a source string, print the result
ljs run <file>        # evaluate a source file
```

## What works today (M0)

- Lexer + precedence-climbing parser → AST for the trivial expression grammar
- Tree-walk interpreter with Completion Records and a step-cap watchdog, carrying inline
  ECMA-262 clause citations
- Values: `undefined`, `null`, boolean, number (f64), string
- Operators: `+ - * / %`, unary `+ - !`, comparisons (`< > <= >=`), `== != === !==`,
  string concatenation, grouping
- `ljs eval` / `ljs run` with spec-correct results and proper stdout/stderr/exit-code behaviour
- First ljs-vs-Node benchmark wired up (lean native startup currently beats Node on tiny scripts;
  that flips once compute-bound benchmarks exist)

## Roadmap

| Milestone | Focus |
|-----------|-------|
| **M0** (in progress) | Test262 harness + minimal eval + ljs-vs-Node benchmarking |
| M1+ | objects, functions, control flow, the built-in library — climbing Test262 % |
| Later | bytecode VM, then optimizing tiers — graduated when the benchmarks justify it |

## Layout

```
src/          engine core (value, completion, lexer, parser, interpreter, engine, CLI)
test262/      conformance harness (planned)
bench/        ljs-vs-Node benchmarks
specs/        Spec-Driven Development artifacts (spec, plan, research, tasks, contracts)
scripts/      tooling (lint, vendor-test262)
```

## Development

Built with Spec Kit — the workflow is `constitution → specify → plan → tasks → implement`.
Quality gates (see the [constitution](.specify/memory/constitution.md)): green build +
`zig build fmt-check` + `zig build lint`, no Test262 regression, no ljs-vs-self perf regression,
spec-clause citations on non-trivial algorithms, and no leaks under the testing allocator.
