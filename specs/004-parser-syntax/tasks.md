---
description: "Task list for M3 — parser/syntax coverage (conformance-driven)"
---

# Tasks: M3 — Parser / Syntax Coverage

**Cadence**: one cycle = one syntax group = one commit (build + test + lint + **bench (ljs ≤ Node)**
green). Re-measure `language/expressions` each cycle (parse_error must drop). Plan folded into the
spec (this is parser/evaluator work; no new architecture).

## Cycle 1 — US1 Operators 🎯 (highest impact/effort)
- [ ] M3-T010 Lexer: `**`/`**=`, `&`/`|`/`^`/`~`, `<<`/`>>`/`>>>`, comma already exists; keywords `void`/`delete`/`in`
- [ ] M3-T011 Parser: precedence for exponent (right-assoc), bitwise, shift, comma operator; `void`/`delete`/`in` unary/binary
- [ ] M3-T012 Interpreter: `**`, bitwise (ToInt32/ToUint32), shifts, comma (eval both, yield right), `void`/`typeof`-style, `in` (has-property)
- [ ] M3-T013 [P] operator tests + re-measure conformance

## Cycle 2 — US2 Template literals
- [ ] M3-T020 Lexer: backtick template tokens (quasi chunks + `${`/`}`); Parser: template node; Interpreter: concat ToString of substitutions

## Cycle 3 — US3 Spread & rest
- [ ] M3-T030 `...` in array literals + call args (flatten iterables/arrays); rest params (`function f(...xs)`)

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
