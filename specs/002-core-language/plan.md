# Implementation Plan: M1 — Core Language Runtime

**Branch**: `002-core-language` | **Date**: 2026-06-15 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/002-core-language/spec.md`

## Summary

Grow the tree-walk engine from trivial expressions to a core language runtime — bindings,
functions/closures, objects with a prototype chain, control flow, exceptions, and the handful
of built-ins the Test262 harness helpers need — then wire harness-include loading so real tests
run. Success = the real-suite pass count goes **> 0** (retiring the M0 D7 deferral). Still
tree-walk, still arena-per-realm (no GC, no bytecode); correctness-first per the constitution.

## Technical Context

**Language/Version**: Zig 0.16.0 (pinned). **Primary Dependencies**: none (std only); Test262 vendored.
**Storage**: filesystem (vendored suite, baselines). **Testing**: `zig build test` + `zig build test262`.
**Project Type**: language engine (single project). **Target Platform**: native (macOS/arm64 dev, Linux CI).
**Performance Goals**: no ljs-vs-Node regression (Principle IV); tree-walk tier retained.
**Constraints**: no UB; no leaks under testing allocator; deep recursion bounded by the step cap.
**Scale/Scope**: built-ins limited to harness needs; SC-003 target slice = `test/language/expressions/addition` (+ relational), aiming pass > 0.

## Constitution Check

| # | Principle | Compliance | Verdict |
|---|-----------|-----------|---------|
| I | Spec is source of truth | Environments (§9), ordinary objects (§10), Error (§20), statements/functions (§13–15) cited inline | ✅ |
| II | Conformance is the gate | SC-003 raises the real-suite number off zero; harness-include loading wired; no regression vs baseline | ✅ |
| III | Spec traceability | New AST/eval mirrors spec productions & abstract operations with clause comments | ✅ |
| IV | Performance measured | tree-walk retained; `zig build bench` run each cycle; no ljs-vs-self regression | ✅ |
| V | Incremental, gated | one cycle per user story (US1→US5), each green + reviewed before commit | ✅ |

**Result**: no violations. Complexity Tracking empty.

## Project Structure

```
src/
├── value.zig         # + object variant (pointer), function value
├── object.zig        # NEW: Object (properties+descriptors, [[Prototype]], ordinary [[Get]]/[[Set]]), kinds: ordinary/function/error/array
├── environment.zig   # NEW: Environment Records (declarative/object/global) + scope chain, Reference resolution
├── ast.zig           # + statements (var/let/const, if/while/for, return/throw/try, block, function decl), member/call/assign/object-literal exprs
├── lexer.zig         # + keywords (var/let/const/function/return/if/else/while/for/throw/try/catch/finally/new/typeof…), `.` `,` `{` `}` `[` `]` `=` `=>`?
├── parser.zig        # + statement & declaration parsing; member/call/assignment; object/array literals
├── interpreter.zig   # + statement evaluation, environments, completions (return/break/continue/throw), [[Call]]
├── builtins.zig      # NEW: Error family, Object, Array (minimal), global env setup
├── engine.zig        # evaluate over a Realm with a global environment
└── main.zig
test262/runner.zig    # wire harness-include loading (io-threaded) + exact-error-type negative classification
tests/                # per-story Zig tests (bindings, functions, objects, control-flow, builtins)
```

**Structure Decision**: extend the existing single project. New modules `object.zig`,
`environment.zig`, `builtins.zig`; the interpreter gains a statement/environment layer.
Functions are objects with a `[[Call]]` (an AST closure or a native Zig fn).

## Phase 0 — Research (decisions)

- **D1 Values/objects**: add `Value.object: *Object`. `Object` = `StringHashMap(Property)` +
  `prototype: ?*Object` + `kind`. Properties carry a minimal descriptor (value + writable);
  full descriptors later. Functions are `Object` of kind `function` holding either an AST
  closure (`*const ast.Function` + captured `*Environment`) or a native `*const fn`.
- **D2 Environments**: a scope chain of `Environment` (parent pointer + `StringHashMap(Binding)`).
  `Binding{ value, mutable, initialized }` gives TDZ (`let`/`const`) and `const` enforcement.
  Resolution returns a Reference (env+name) for assignment.
- **D3 Completions**: extend `Completion` to `normal/throw/return/break/continue` so statement
  eval threads control flow (§6.2.4). `try/catch/finally` handles `throw`.
- **D4 Memory**: arena-per-realm — objects/environments live for the realm's lifetime. No GC in
  M1 (Assumption); revisit under memory pressure. Each Test262 execution still gets a fresh realm.
- **D5 Built-ins scope**: implement only what `sta.js`/`assert.js` reference (Error family +
  `Object`, basic `Array`, `Function.prototype.call`?, the globals they touch). Read the actual
  vendored `harness/assert.js` to enumerate the exact surface during US5.
- **D6 Harness loading**: thread `io` into `buildSource`; for non-`raw` tests prepend
  `sta.js`+`assert.js`+`includes` read from `--harness-dir`. Tighten negative-runtime
  classification to compare the thrown object's `name` to `negative.type` (FR-008).
- **D7 (amendment, after M1-T050)**: reading the vendored `sta.js`/`assert.js` showed US5
  needs far more than first planned — `typeof`, `||`/`&&`, `new`+constructors (`.prototype`),
  `instanceof`, `String()`, `Function.prototype.call`, `Object.prototype`/`Array.prototype`
  methods. US5 is therefore split into **E1** (operators + construction), **E2** (core
  built-ins + global env), **E3** (wire harness + tighten classification + first real passes).
  `JSON` is NOT needed (assert.js guards `typeof JSON !== "undefined"`). One cycle per
  sub-phase, each gated as usual.

## Phase 1 — Design artifacts
- `data-model.md`: Value(+object), Object, Property/Descriptor, Environment, Binding, Reference, Completion(extended), Function, Error.
- `quickstart.md`: per-story validation commands + the real-slice pass-count check (SC-003).
- contracts: CLI unchanged; harness `--harness-dir` becomes functional (update cli.md note).

## Complexity Tracking
> No constitution violations — section intentionally empty.
