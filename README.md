# ljs

A JavaScript engine written from scratch in [Zig](https://ziglang.org) — **spec-first**, optimized
for correctness and Test262 conformance, with a measured (not deferred) performance story.

> **Status:** tree-walk interpreter passing **90.9% of Test262 `language/`** (40,414 / 44,475).
> The standard built-in library (`built-ins/`) is in progress. A learning-grade, in-progress
> engine — not a drop-in Node replacement.

Built with **Spec-Driven Development** ([Spec Kit](https://github.com/github/spec-kit)): every
operation cites an [ECMA-262](https://tc39.es/ecma262/) clause, conformance is judged by the
official [Test262](https://github.com/tc39/test262) suite, and performance is gated against Node
(V8) with an ljs-vs-self no-regression check from the first runnable build.

## Scope — 100% ECMAScript, no Node host APIs

The target is **full ECMAScript conformance**: the JS *language* plus the standard built-in
*library* — exactly what Test262 covers under `test/language/` and `test/built-ins/`. Nothing more.

**In scope (it's ECMA-262):**
- The complete language: bindings, functions/closures, objects & prototypes, classes (incl.
  private `#x`, `static {}`), control flow, operators, destructuring, modules (`import`/`export`
  grammar + linking/evaluation, dynamic `import()`), and strict-mode early errors.
- The built-in library: `Object`, `Array`, `String`, `Number`, `Math`, `Symbol`, `BigInt`,
  `Map`/`Set`/`WeakMap`/`WeakSet`, `Proxy`/`Reflect`, `JSON`, `RegExp`, the `Error` family,
  iterators + iterator helpers.
- Generators, async/await, and **Promises + the microtask / Job queue** — these are ECMA-262, not
  the host.
- **UTF-16 string semantics** (§6.1.4): `length`/indexing/methods over code units, WTF-8 storage
  with an ASCII fast path.

**Out of scope — Node / host runtime APIs:**
- CommonJS `require`, ESM *host* module loading, `fs` / `http` / `net` / `process` / `Buffer`.
- Host timers `setTimeout` / `setInterval`.
- These are host embeddings, not ECMA-262. (A minimal test-harness module loader exists only to
  drive the Test262 module corpus — it is not a general host API.)

**Stop rule:** when the only remaining work to advance conformance would be a Node host API, that
work is out of scope.

## Quick start

Requires **Zig 0.16.0** (pinned). Node.js and [ZLint](https://github.com/DonIsaac/zlint) are optional.

```sh
zig build                       # build the `ljs` executable
zig build run -- eval "2 * (3 + 4)"   # => 14
ljs run <file>                  # evaluate a source file

zig build test                  # unit tests
zig build lint                  # zig fmt --check + ZLint
zig build bench                 # ljs (ReleaseFast) vs Node, perf-regression gated
```

## Conformance (Test262)

The corpus is TC39's ~50k-file suite — gitignored and fetched at a pinned commit:

```sh
zig build vendor                # sparse-checkout test/language + test/built-ins → vendor/test262/
# run with the regression gate against the committed baseline (exit 1 on regression):
zig build test262 -- --path vendor/test262/test/language  --harness-dir vendor/test262/harness --baseline baseline/language.json
zig build test262 -- --path vendor/test262/test/built-ins --harness-dir vendor/test262/harness --baseline baseline/builtins.json
```

Numbers are the standard Test262 harness metric (with `--harness-dir`). Only the engine's own
tests, the `baseline/*.json` passing-set snapshots, and the `specs/` SDD docs are in git; the
corpus is reproducible from `test262.pin`.

The largest remaining `built-ins/` gaps are big *separate* engines — `Temporal`, `Intl`,
`TypedArray`/`ArrayBuffer`/`DataView`/`Atomics`, `Date` — alongside method-family gaps in the core
prototypes.

## Architecture

A tree-walk interpreter, pure `std`, no external deps. The interpreter and parser are split into
focused per-subsystem modules (`interp_*.zig`, `parse_*.zig`) with thin cores; new behavior goes
in the relevant module (see [CLAUDE.md](CLAUDE.md) → "Code organization").

```
src/          engine: value, object, environment, lexer, parser (+ parse_*), interpreter (+ interp_*), builtin_*, CLI
test262/      conformance harness (runner, frontmatter metadata, report + baseline)
bench/        ljs-vs-Node benchmarks (gated on min time)
specs/        Spec-Driven Development artifacts (spec, plan, tasks)
scripts/      tooling (lint, vendor-test262)
```

**Performance:** built with `ReleaseFast`, ljs is ~2–3× faster than Node on the short benchmark
workloads — a native binary boots in ~0 ms vs V8's ~24 ms. V8's JIT wins on heavy *sustained*
compute; that crossover is the signal to graduate ljs from tree-walk to a bytecode VM (future work).

## Development

Spec-Kit workflow: `constitution → specify → plan → tasks → implement`. Per-cycle gate (see the
[constitution](.specify/memory/constitution.md)): green **build → test → lint → conformance
(no regression) → bench (no regression)**, plus spec-clause citations on non-trivial algorithms
and no leaks under the testing allocator.
```
