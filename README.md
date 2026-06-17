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
> enough to load the Test262 harness (both `propertyHelper.js` and `compareArray.js` now fully load),
> plus generators (`function*` / `yield` / `yield*`). Conformance is now tracked over the **whole
> `language/` tree**: **40.9%** of `language/` (14,039 / 39,913, harness metric), of which
> `language/expressions` is **46.7%** (7,922 / 19,215). Async is a later milestone. The
> bytecode/JIT tiers are future work. A learning-grade, in-progress engine, not a drop-in Node replacement.

> **Scope: 100% ECMAScript, no Node host APIs.** ljs targets full ECMAScript conformance — the JS
> language plus the standard built-in library, i.e. exactly Test262's `test/language/` and
> `test/built-ins/`. It deliberately does **not** implement Node/host runtime APIs (CommonJS
> `require` / module loading, ESM host loading, `fs` / `http` / `net` / `process` / `Buffer`, host
> timers `setTimeout` / `setInterval`). Promises and the microtask / Job queue **are** in scope —
> they're ECMA-262, not the host.

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

## Getting started (clone → build → test)

```sh
# Prerequisites: Zig 0.16.0 (pinned). Optional: ZLint (for `zig build lint`), Node (for the bench
# ljs-vs-Node ratio — the bench still runs without it).

zig build                 # compile the engine + CLI + harness
zig build test            # run the engine unit tests (in src/engine.zig) — no Test262 needed

# Test262 conformance corpus is gitignored (it's TC39's ~50k-file suite); fetch the pinned commit:
zig build vendor          # sparse-checkout test/language + test/built-ins at test262.pin → vendor/test262/

# run conformance (with the regression gate against the committed baseline):
zig build test262 -- --path vendor/test262/test/language  --harness-dir vendor/test262/harness --baseline baseline/language.json
zig build test262 -- --path vendor/test262/test/built-ins --harness-dir vendor/test262/harness --baseline baseline/builtins.json
zig build lint            # zig fmt --check + ZLint
zig build bench           # ljs (ReleaseFast) vs Node, gated on no ljs-vs-self perf regression
```

The per-cycle gate (spec-driven dev): **build → test → lint → conformance (no regression) → bench
(no regression)**, each cycle is one commit. The conformance corpus is reproducible from
`test262.pin` (not committed); only the engine's own tests, the `baseline/*.json` passing-set
snapshots, and the SDD docs in `specs/` are in git.

## Conformance (Test262)

**Scope:** the conformance target is 100% **ECMAScript** — the JS language + standard built-in
library, i.e. Test262's `test/language/` and `test/built-ins/`. Node/host APIs (CommonJS/ESM host
module loading, `fs`/`http`/`net`/`process`/`Buffer`, host timers) are explicitly out of scope;
Promises + the microtask/Job queue are in scope (they're ECMA-262). Conformance is now tracked over
**both** the whole `language/` tree **and** the `built-ins/` tree (the standard library — the bulk of
the remaining work toward 100% ECMAScript).

```sh
# vendor BOTH trees (fast sparse checkout), pinned via test262.pin
./scripts/vendor-test262.sh test/language test/built-ins
zig build test262 -- --path vendor/test262/test/language  --harness-dir vendor/test262/harness
zig build test262 -- --path vendor/test262/test/built-ins --harness-dir vendor/test262/harness
# (a narrower slice, e.g. just expressions, also works:)
# ./scripts/vendor-test262.sh test/language/expressions
# baseline + regression gate:
zig build test262 -- --path <dir> --harness-dir vendor/test262/harness --update-baseline baseline/<name>.json
zig build test262 -- --path <dir> --harness-dir vendor/test262/harness --baseline baseline/<name>.json   # exit 1 on regression
```

**Current headline (HEAD, harness metric):** full `language/` → **34,177 passed / 44,475 total /
809 skipped = 78.3%**. Baselines: `baseline/language.json` (full tree, the milestone metric) and
`baseline/language-expressions.json` (the expressions slice, kept for continuity). The remaining
`language/` failures are now mostly runtime edge cases (`class` long tail, iterator/async details)
plus the not-yet-implemented `dynamic-import` (host), regex literals, and `BigInt`.

**Built-ins baseline (M37, harness metric):** the `built-ins/` tree (the standard library, 23,646
test files) measures **≈7,690 passed / ≈45,500 mode-runs = ≈16.9%** at this milestone. `built-ins/`
is now vendored, measured, and gated via `baseline/builtins.json` (7,744 passing test ids). M37 is an
**infrastructure + measurement** cycle — no engine feature changed; it opens the standard library up
for the subsequent stdlib milestones. The failure split is overwhelmingly `unexpected_error` (~82% —
positive tests that throw `TypeError: … is not a function` because a built-in method is missing), so
the recoverable clusters are whole method families. The largest failing top-level objects are
`Temporal`, `RegExp`, `TypedArray`/`DataView`/`ArrayBuffer`/`Atomics` (the binary/typed-array engine)
and `Date` — these are big *separate* engines; the realistic near-term stdlib wins are the
prototype/static method gaps in **`Object`** (2,501 fails, already 63%), **`Array`** (≈5,200 fails),
**`String`** (1,953 fails) and **`Iterator`** helpers (1,014 fails). Note: a handful of `Array`
partitions (`length`, `prototype/{indexOf,lastIndexOf,slice}` and the top-level `Array` files) trip an
engine memory blowup when a test sets a very large `array.length` (eager backing-store
materialization), so they are excluded from the measured numbers and the baseline until that is fixed.

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

**M8 result (iterator protocol + Symbol, harness metric):** `test/language/expressions` → **6,825 passed =
40.2%**. A minimal §20.4 Symbol (the `symbol` primitive — `typeof "symbol"`, identity equality,
description, implicit Symbol→string throws but `String()`/`.toString()` allowed; `Symbol()` callable that
rejects `new`; the well-known symbols `iterator`/`asyncIterator`/`toStringTag`/`hasInstance`; a separate
non-enumerated symbol-keyed property store leaving the string get/set hot path untouched) unblocks the
§7.4 iteration protocol (`getIterator`/`iteratorStep`/`iteratorClose`/`iterateToList`), which is then wired
into for-of (with IteratorClose on break/return/throw), spread, and array destructuring — so a user object
with `[Symbol.iterator]` is iterable everywhere, with native `Array`/`String` iterators on a fast-path.
Cycle 1: **39.6% → 40.2%** (passed 6,718 → 6,825, **+107**), 0 true regressions / 107 recoveries by
`mode+path`, bench-green (the symbol store is a separate map; the for-of/spread native-iterator fast-path
keeps Arrays/Strings off the per-element `.next()` dispatch). Deferred: the Symbol registry
(`Symbol.for`/`keyFor`), the full Symbol surface, `Map`/`Set`, async iteration, and — the big remaining
lever — generators/`yield` (the language-level iterator producer), next.

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
| **M8** | **iterator protocol + Symbol** — minimal §20.4 Symbol (the `symbol` primitive + `Symbol()` + well-known symbols + a non-enumerated symbol-keyed store) + the §7.4 protocol (`getIterator`/`iteratorStep`/`iteratorClose`) wired into for-of (IteratorClose on break/return/throw) / spread / array destructuring + native `Array`/`String` iterators | ✅ done (39.6% → 40.2% of expressions, harness metric, +107; bench green, ljs 0.2–0.5× Node) |
| **M9** | **generators** — `function*` / `yield` / `yield*` delegation + generator methods | ✅ done (40.2% → 46.7% of expressions, harness metric) |
| M10+ | `Map`/`Set`, then Promise + microtask/Job queue + async/await — climbing Test262 % over the full `language/` tree (then `built-ins/`) | next |
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
