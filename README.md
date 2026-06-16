# ljs

A JavaScript engine written from scratch in [Zig](https://ziglang.org) — in the spirit of V8,
but built **spec-first** and optimized for correctness, spec-traceability, and a measured
performance story from day one.

> **Status: M4 (classes) closed.** A tree-walking interpreter runs variables,
> functions/closures, objects, control flow, exceptions, the full modern-syntax surface
> (operators, template literals, spread/rest, destructuring, arrow functions, object-literal sugar,
> `?.`/`??`, the complete assignment-operator set, and strict-mode Early Errors), the full
> **class** surface (declarations/expressions, constructor, methods, fields, statics, `extends`/`super`,
> accessors, computed names, private `#x`, and `static {}` blocks), `for-in`/`for-of` enumeration, and
> the **property-descriptor / reflection** API (`Object.defineProperty`/`getOwnPropertyDescriptor(s)`/
> `getOwnPropertyNames`/`keys`/`values`/`entries`/`create`/`assign`/`is`/`getPrototypeOf`/`setPrototypeOf`/
> `freeze`/`seal`/`preventExtensions`, `Object.prototype.hasOwnProperty`/`propertyIsEnumerable`/
> `isPrototypeOf`, and `Function.prototype.call`/`apply`/`bind`), and **destructuring assignment**
> (`[a, b] = arr`, `({x, y} = obj)`, holes / defaults / rest / nested / member-index targets, §13.15.5) —
> enough to load the Test262 harness (both `propertyHelper.js` and `compareArray.js` now fully load) and
> pass **39.6%** of `language/expressions` (6,718 tests, harness metric). Generators and async are later milestones. The
> bytecode/JIT tiers are future work. A learning-grade, in-progress engine, not a drop-in Node replacement.

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

## What works today (M0–M4)

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
- **Classes (M4)**: `class` **declarations & expressions**, explicit/default **constructor**,
  instance **methods** & **fields**, **static** methods/fields, `new`, **`extends`/`super`**
  (`super(…)`, `super.m()`, prototype + static inheritance, `extends null`), **`get`/`set` accessors**,
  **computed names** `[expr]`, **private** `#x` fields/methods/accessors with brand checks + `#x in obj`,
  **`static { … }`** initialization blocks, and the §15.7.1 / §13.3.5.1 / §13.3.7.1 parse-phase Early
  Errors (always-strict class body). Generator/async class methods are deferred (parse-reject).
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

**M4 result (harness metric):** `test/language/expressions` → **6,077 passed / 10,894 failed /
2,244 skipped = 35.8%**. Classes (the biggest single conformance lever — ≈2,405 unique failing
class files at M3 close) drained across five cycles: C1 core (decl/expr, ctor, methods, fields,
statics, `new`), C2 `extends`/`super` (+42), C3 accessors + computed names (+240), C4 private `#x` +
`static {}` (+311), C5 §15.7.1 Early-Errors audit + close (+0; all already enforced). M4 total:
**32.3% → 35.8%** (passed 5,484 → 6,077, **+593**), 0 true regressions per cycle by `mode+path`,
bench-green throughout (ljs 0.2–0.5× Node). The harness also validates
classification, fault isolation, determinism, and regression detection.

**M6 result (reflection / property-descriptor built-ins, harness metric):** `test/language/expressions`
→ **6,509 passed = 38.4%**. The §6.1.7.1 property-attribute model (writable/enumerable/configurable per
own property) + `[[Extensible]]` + the §20.1.2/§20.1.3/§20.2.3 reflection API unblock the two harness
files behind a large fraction of positive tests: **propertyHelper.js** (`verifyProperty`) and
**compareArray.js** (`assert.compareArray`) now both fully load. Three cycles: C1 descriptor model +
`Object`/`Object.prototype` reflection + enumerable-aware for-in/spread (+62), C2
`Function.prototype.call`/`apply`/`bind` → propertyHelper.js loads (+248), C3
`Object.keys`/`values`/`entries`/`create`/`assign`/`is`/`getPrototypeOf`/`setPrototypeOf` +
`freeze`/`seal`/`preventExtensions` (with integrity enforcement) + insertion-ordered own-property keys
(§10.1.11.1) (+122). M6 total: **35.8% → 38.4%** (passed 6,077 → 6,509, **+432**), 0 true regressions per
cycle by `mode+path`, bench-green throughout (ljs 0.2–0.5× Node). Deferred: `Reflect.*`, `Proxy`, the full
§10.1.6.3 invariant matrix, strict-mode write/delete TypeErrors, and Symbol-keyed properties.

**M7 result (destructuring assignment, harness metric):** `test/language/expressions` → **6,718 passed =
39.6%**. The §13.15.5 cover-grammar refinement in `parseAssignment` (an un-parenthesized ArrayLiteral/
ObjectLiteral on the LHS of `=` is refined to an AssignmentPattern) + a parallel `assignPattern` evaluator
(PUT each leaf into an existing reference — identifier / `a.b` / `a[k]` / nested pattern, with holes /
defaults / array rest / object rest, single RHS eval) unblock the `assignment/dstr` subtree (it was ~all
`parse_error`). Cycle 1: **38.4% → 39.6%** (passed 6,509 → 6,718, **+209**), 0 true regressions / 209
recoveries by `mode+path` (167 `assignment/dstr`, 16 `class/dstr`, + `object`/`function`/`arrow-function`
dstr and the array-literal-elision tests), bench-green (the refinement is parse-time; `assignPattern`
never runs in the hot loop). The §13.2.5.1 CoverInitializedName + §13.15.5.1 rest-placement /
non-assignable-leaf / parenthesized-literal parse-phase early errors keep the negatives green. Deferred:
the full iterator protocol (`Symbol.iterator` / iterator-close / generators) for the `assignment/dstr` +
`object/dstr` remainder. Generators/async next.

## Roadmap

| Milestone | Focus | Status |
|-----------|-------|--------|
| **M0** | Test262 harness + minimal eval + ljs-vs-Node benchmarking | ✅ done |
| **M1** | bindings, functions, objects, control flow, errors → run the harness | ✅ done (23.3% of expressions) |
| **M2** | core built-in library — arrays, strings | ✅ done |
| **M3** | parser / syntax coverage — 9 cycles, drain the `parse_error` bottleneck | ✅ done (23.3% → 27.2% of expressions; bench green throughout, ljs 0.2–0.5× Node) |
| **M4** | **classes** — decl/expr, constructor, methods, fields, statics, `extends`/`super`, accessors, computed names, private `#x`, `static {}` blocks | ✅ done (32.3% → 35.8% of expressions, harness metric, +593; bench green, ljs 0.2–0.5× Node) |
| **M5** | **`for-in` / `for-of`** — enumeration parse + iteration scaffold | ✅ done (held 35.8%; the enumeration prerequisite for M6's enumerable-awareness) |
| **M6** | **reflection / property descriptors** — §6.1.7.1 attributes + `[[Extensible]]`, `Object.defineProperty`/`getOwnPropertyDescriptor(s)`/`getOwnPropertyNames`/`keys`/`values`/`entries`/`create`/`assign`/`is`/`getPrototypeOf`/`setPrototypeOf`/`freeze`/`seal`/`preventExtensions`, `Object.prototype.hasOwnProperty`/`propertyIsEnumerable`/`isPrototypeOf`, `Function.prototype.call`/`apply`/`bind`; unblocks `propertyHelper.js` + `compareArray.js` | ✅ done (35.8% → 38.4% of expressions, harness metric, +432; bench green, ljs 0.2–0.5× Node) |
| **M7** | **destructuring assignment** — §13.15.5 cover-grammar refinement (`[a,b]=arr`, `({x,y}=obj)`) + `assignPattern` (holes / defaults / array+object rest / nested / member-index-private targets, single RHS eval) + §13.2.5.1/§13.15.5.1 early errors | ✅ done (38.4% → 39.6% of expressions, harness metric, +209; bench green, ljs 0.2–0.5× Node) |
| M8+ | generators / async — climbing Test262 % | next |
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
