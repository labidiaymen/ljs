# ljs

A JavaScript engine written from scratch in [Zig](https://ziglang.org) — in the spirit of V8,
but built **spec-first** and optimized for correctness, spec-traceability, and a measured
performance story from day one.

> **Status: M1 (core language).** A tree-walking interpreter runs variables, functions/closures,
> objects, control flow, and exceptions — enough to load the Test262 harness and pass **~23%**
> of `language/expressions` (3,954 tests). The bytecode/JIT tiers are future work. A
> learning-grade, in-progress engine, not a drop-in Node replacement.

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

## What works today (M1)

- **Bindings & scope**: `var`/`let`/`const`, assignment + compound (`+= -= *= /= %=`), `++`/`--`,
  block (lexical) scope; `const`-reassign → TypeError, unresolved → ReferenceError
- **Functions**: declarations/expressions, parameters, `return`, calls, **closures**, basic `this`
- **Objects**: literals, `a.b` / `a[k]` access + assignment, prototype chain, `new` + constructors,
  `instanceof`, `typeof`
- **Control flow**: `if`/`else`, `while`, `for`, `break`/`continue`, `switch`, `throw`/`try`/`catch`/`finally`
- **Operators**: arithmetic, comparisons, `=== !==`, logical `||`/`&&` (short-circuit), ternary `?:`
- **Built-ins**: the `Error` family (real typed objects), `String()`, minimal `Object`
- **Engine**: Completion Records, Environment Records, a step-cap + recursion-depth guard
  (deep recursion → `RangeError`, never a crash); inline ECMA-262 clause citations throughout
- Runs the **Test262 harness** (`sta.js`/`assert.js`) and passes real conformance tests

## Conformance (Test262)

```sh
# vendor a slice of the official suite (fast sparse checkout), pinned via test262.pin
./scripts/vendor-test262.sh test/language/expressions
zig build test262 -- --path vendor/test262/test/language/expressions --harness-dir vendor/test262/harness
# baseline + regression gate:
zig build test262 -- --path <dir> --harness-dir vendor/test262/harness --update-baseline baseline/<name>.json
zig build test262 -- --path <dir> --harness-dir vendor/test262/harness --baseline baseline/<name>.json   # exit 1 on regression
```

**M1 result:** `test/language/expressions` → **3,954 passed / 13,017 failed / 2,244 skipped = 23.3%**
(11,158 test files). Real positive tests pass via the loaded `assert.js`; the rest fail/skip on
features still to come (full string/array built-ins, generators, etc.). The harness also validates
classification, fault isolation, determinism, and regression detection.

## Roadmap

| Milestone | Focus | Status |
|-----------|-------|--------|
| **M0** | Test262 harness + minimal eval + ljs-vs-Node benchmarking | ✅ done |
| **M1** | bindings, functions, objects, control flow, errors → run the harness | ✅ done (23.3% of expressions) |
| M2+ | full string/array/built-in library, more of the spec — climbing Test262 % | next |
| Later | bytecode VM, then optimizing tiers — graduated when the benchmarks justify it | future |

**Performance note:** built with `ReleaseFast`, ljs is currently **2–5× faster than Node** on
the benchmark workloads — its native binary starts in ~0 ms vs V8's ~24 ms boot, which dominates
these short/medium scripts. V8's JIT will win on heavy *sustained* compute; that's the signal
that will justify graduating ljs to a bytecode VM.

## Layout

```
src/          engine core (value, object, environment, completion, lexer, parser, interpreter, builtins, engine, CLI)
test262/      conformance harness (runner, frontmatter metadata, report + baseline)
bench/        ljs-vs-Node benchmarks (loop-based; gated on min time)
specs/        Spec-Driven Development artifacts (spec, plan, research, tasks, contracts)
scripts/      tooling (lint, vendor-test262)
```

## Development

Built with Spec Kit — the workflow is `constitution → specify → plan → tasks → implement`.
Quality gates (see the [constitution](.specify/memory/constitution.md)): green build +
`zig build fmt-check` + `zig build lint`, no Test262 regression, no ljs-vs-self perf regression,
spec-clause citations on non-trivial algorithms, and no leaks under the testing allocator.
