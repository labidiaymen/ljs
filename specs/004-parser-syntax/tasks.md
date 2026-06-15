---
description: "Task list for M3 — parser/syntax coverage (conformance-driven)"
---

# Tasks: M3 — Parser / Syntax Coverage

**Cadence**: one cycle = one syntax group = one commit (build + test + lint + **bench (ljs ≤ Node)**
green). Re-measure `language/expressions` each cycle (parse_error must drop). Plan folded into the
spec (this is parser/evaluator work; no new architecture).

## Cycle 1 — US1 Operators 🎯 (DONE — conformance 23.3% → 24.2%, +147)
- [x] M3-T010 Lexer: `**`, `&`/`|`/`^`/`~`, `<<`/`>>`/`>>>`, `in` keyword
- [x] M3-T011 Parser: full precedence table (logical→bit→eq→rel/in→shift→add→mul→exp); `**` right-assoc; `~` unary
- [x] M3-T012 abstract_ops `ToInt32`/`ToUint32`; interpreter: `**`, bitwise (int32), shifts (wrap/arith/logical), `in` has-check, `~`
- [x] M3-T013 [P] operator tests (12, inline) + re-measure: **24.2%** (+147 tests). Bench green (ljs ≤ Node).
> Deferred from US1: comma operator, `void`/`delete` (lower frequency; need an expression-comma layer / assignable-target delete — revisit if the breakdown shows them dominant).

## Cycle 2 — US2 Template literals (DONE)
- [x] M3-T020 `a${x}b` template literals: lexer raw-scan (brace-tracked), parser quasi/expr split + sub-parse (nested + escapes), interpreter ToString-concat. Conformance flat on expressions (24.2%) — templates are rare there.
- [x] M3-T021 **Perf fix** (bench gate caught a real ~15% loop slowdown across M2/M3): blocks allocate a child scope only when they lexically declare (let/const/function); declaration-free bodies reuse the parent env → no per-iteration alloc. loop_sum now *beats* its baseline. Behavior-preserving.

## Cycle 3 — US3 Spread & rest (DONE — conformance 23.6% → 25.3%, +289)
- [x] M3-T030 `...` in array literals + call/new args (flatten arrays + strings); rest params (`function f(...xs)` → leftover args bound as an Array). Lexer `ellipsis`, `spread` AST node, `parseSpreadable`, `evalSpreadList`, rest-param binding in `[[Call]]`.
- [x] M3-T031 Spread-correctness boundary: ImportCall (§13.3.10) forbids `...` (a Forbidden Extension), so `import(...x)` must not parse as a spread call. `import` is a reserved word the engine doesn't implement → recognized as `kw_import` and parse-rejected (SyntaxError). This fixes the spread-induced regression on `dynamic-import/syntax/invalid/*-no-rest-param` AND converts the other invalid-ImportCall negatives (empty/extra-args/`new import()`) to passes → net +289. Known gap: 18 `dynamic-import/syntax/valid` tests (import appears but isn't evaluated) now parse-fail; recovering them needs real ImportCall parsing — deferred to a future modules/dynamic-import milestone.

## Cycle 4 — US4 Destructuring
- [ ] M3-T040 Array/object binding patterns in `var`/`let`/`const` + params (with defaults/holes)

## Cycle 5 — US5 Arrow functions
- [ ] M3-T050 `=>` (expr + block body); lexical `this` (capture enclosing `this_val`)

## Cycle 6 — US6 Object-literal extensions + access operators
- [ ] M3-T060 Getters/setters, shorthand `{x}`, computed `{[k]:v}`, method shorthand; `?.` and `??`

## Close
- [ ] M3-T070 Record conformance baseline (SC-001, target ≥35%); README/roadmap; bench green; no M0/M1 regression

## Dependencies / order
Ordered by impact-to-effort: operators first (cheap, common), then template literals, then the
bigger structural features (spread/destructuring/arrow), then object-literal sugar + access ops.
Each cycle bench-gated.
