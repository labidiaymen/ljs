# ljs

A JavaScript engine written from scratch in [Zig](https://ziglang.org) — in the spirit of V8,
but built **spec-first** and optimized for correctness, spec-traceability, and a measured
performance story from day one.

> **Status: M3 (parser / syntax) closed.** A tree-walking interpreter runs variables,
> functions/closures, objects, control flow, exceptions, and now the full modern-syntax surface
> (operators, template literals, spread/rest, destructuring, arrow functions, object-literal sugar,
> `?.`/`??`, the complete assignment-operator set, and strict-mode Early Errors) — enough to load
> the Test262 harness and pass **32.6%** of `language/expressions` (5,526 tests, harness metric).
> Classes, generators, and async are later milestones. The bytecode/JIT tiers are future work. A
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

## What works today (M0–M3)

- **Bindings & scope**: `var`/`let`/`const`, assignment + compound (the full set incl.
  `**= <<= >>= >>>= &= |= ^=`) and logical assignment (`&&= ||= ??=`), `++`/`--`,
  block (lexical) scope; `const`-reassign → TypeError, unresolved → ReferenceError
- **Functions**: declarations/expressions, parameters, `return`, calls, **closures**, basic `this`,
  **arrow functions** (`=>`, lexical `this`), rest params, destructuring params
- **Objects**: literals + sugar (shorthand `{x}`, computed `{[k]:v}`, method `{m(){…}}`, spread
  `{...o}`, getters/setters), `a.b` / `a[k]` access + assignment, **optional chaining `?.`**,
  prototype chain, `new` + constructors, `instanceof`, `typeof`
- **Control flow**: `if`/`else`, `while`, `for`, `break`/`continue`, `switch`, `throw`/`try`/`catch`/`finally`
- **Operators**: arithmetic + **exponent `**`**, bitwise `& | ^ ~`, shifts `<< >> >>>`, comparisons,
  `=== !==`, logical `||`/`&&` (short-circuit), **nullish `??`**, ternary `?:`, comma/sequence,
  `void`/`delete`/`in`
- **Syntax (M3)**: **template literals** (`` `a${x}b` ``), **spread/rest** `...` in arrays/calls/params,
  **array & object destructuring** (declarations + params, defaults/holes/rest/nesting),
  **strict-mode context** with the spec's parse-phase Early Errors (`"use strict"` directive
  prologue, reserved/`eval`/`arguments` binding restrictions, strict `delete` of a bare reference)
- **Built-ins**: the `Error` family (real typed objects), `String()`, arrays/strings (M2),
  the §19.1 global values `undefined`/`NaN`/`Infinity`, minimal `Object`
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

**Metric:** conformance is reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`, the standard Test262 way). The prior bare-gate numbers undercounted positive
tests that call `assert.*`; e.g. at commit `9320218` (M4 Cycle 1) the same code measured bare **27.2%**
vs harness **32.3%** on `language/expressions` (passed 4,622 → 5,484). The committed baseline
`baseline/language-expressions.json` and all M4+ deltas use the harness metric.

**M4 Cycle 2 result (harness metric):** `test/language/expressions` → **5,526 passed / 11,445 failed /
2,244 skipped = 32.6%** (Cycle 1 was 5,484 = 32.3%; Cycle 2 added `extends` + `super`, +42, 0 true
regressions). M3's nine syntax cycles moved this from the **M1 baseline of 23.3%** by draining the
`parse_error` bucket; M4 is draining the class bucket (**classes alone are ≈2,405 unique failing test
files**), with generators/async next. The harness also validates classification, fault isolation,
determinism, and regression detection.

## Roadmap

| Milestone | Focus | Status |
|-----------|-------|--------|
| **M0** | Test262 harness + minimal eval + ljs-vs-Node benchmarking | ✅ done |
| **M1** | bindings, functions, objects, control flow, errors → run the harness | ✅ done (23.3% of expressions) |
| **M2** | core built-in library — arrays, strings | ✅ done |
| **M3** | parser / syntax coverage — 9 cycles, drain the `parse_error` bottleneck | ✅ done (23.3% → 27.2% of expressions; bench green throughout, ljs 0.2–0.5× Node) |
| M4+ | **classes** (the biggest conformance lever), then generators/async — climbing Test262 % | next |
| Later | bytecode VM, then optimizing tiers — graduated when the benchmarks justify it | future |

M3's nine cycles: operators (`**`, bitwise, shifts, `in`) · template literals · spread/rest ·
destructuring · arrow functions · object-literal sugar + `?.`/`??` · the complete
assignment-operator set · comma/`void`/`delete` · strict-mode context + Early Errors. Each cycle
re-measured `language/expressions` conformance and stayed bench-green (ljs ≤ Node). SC-001's ≥35%
target was **not** reached (27.2%): the remaining levers — classes (≈39% of failures), then
generators/async — are M4+ scope, not M3 syntax.

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
