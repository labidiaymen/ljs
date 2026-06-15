# Feature Specification: M3 — Parser / Syntax Coverage

**Feature Branch**: `004-parser-syntax`

**Created**: 2026-06-15

**Status**: Draft

**Input**: "M3: parser/syntax coverage to clear the parse_error bottleneck"

## Why (data-driven)
At M2 Cycle-2 close, `test/language/expressions` failures were **10,763 `parse_error`** vs only
1,817 `unexpected_error` and 431 negative-mismatch. The dominant blocker is **missing syntax**,
not missing built-ins. M3 attacks the parse_error bucket — the ~6× larger conformance win — by
adding the operators and syntactic forms real tests use.

## User Scenarios & Testing *(mandatory)*
Users: engine devs / CI. Each cycle adds a coherent syntax group, re-measures
`language/expressions` conformance (which should now climb), and stays bench-green (ljs ≤ Node).

### US1 — Operators (P1)
Exponent `**`, bitwise `& | ^ ~`, shifts `<< >> >>>`, the comma operator, and `void`/`delete`/`in`.
**Test**: `2 ** 10` → 1024; `5 & 3` → 1; `1 << 4` → 16; `(1, 2, 3)` → 3.

### US2 — Template literals (P1)
Backtick strings with `${expr}` interpolation (no tagged templates yet).
**Test**: `` `a${1+1}b` `` → "a2b".

### US3 — Spread & rest (P2)
`...` in array literals, call arguments, and rest parameters.
**Test**: `[...[1,2], 3].length` → 3; `Math.max(...[1,9,4])` (once Math lands) ; `function f(...xs){return xs.length} f(1,2,3)` → 3.

### US4 — Destructuring (P2)
Array/object binding patterns in declarations and parameters.
**Test**: `var [a, b] = [1, 2]; a + b` → 3; `var {x, y} = {x:1, y:2}; x + y` → 3.

### US5 — Arrow functions (P2)
`(a, b) => expr` and `x => { ... }`, lexical `this`.
**Test**: `var add = (a, b) => a + b; add(2, 3)` → 5.

### US6 — Object-literal extensions & access operators (P3)
Getters/setters, shorthand `{x}`, computed keys `{[k]: v}`, method shorthand; optional chaining
`?.` and nullish `??`.
**Test**: `var o = {get v() { return 7; }}; o.v` → 7; `var o = null; o?.x` → undefined; `null ?? 5` → 5.

### Edge Cases
- Operator precedence (`**` right-assoc, binds tighter than unary minus per spec quirk).
- Spread of non-iterables; destructuring with defaults / missing values.
- Arrow `this` is lexical (no own `this`/`arguments`).

## Requirements *(mandatory)*
- **FR-001**: Lex + parse + evaluate the US1 operators with correct precedence/associativity and ECMA-262 numeric semantics (ToInt32/ToUint32 for bitwise).
- **FR-002**: Template literals parse (quasis + substitutions) and evaluate to the concatenated string.
- **FR-003**: Spread/rest parse and evaluate in array literals, call args, and parameters.
- **FR-004**: Array/object destructuring patterns bind in declarations and parameters.
- **FR-005**: Arrow functions parse and evaluate with lexical `this`.
- **FR-006**: Getters/setters, shorthand/computed/method object properties; `?.` and `??`.
- **FR-007**: Spec-clause citations on new productions (Principle III).
- **FR-008**: ljs ≤ Node on the bench (absolute pre-commit gate); no M0/M1 regression.

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `parse_error` count **drops substantially** and overall conformance rises above 23.3% (re-measured each cycle; target ≥ 35%).
- **SC-002**: ≥40 syntax unit tests pass.
- **SC-003**: M0 curated sample still 27/6/2; bench green (ljs ≤ Node); no leaks.

## Assumptions
- Tree-walk tier retained; this is parser/evaluator work, not built-ins.
- Tagged templates, generators (`function*`), async, and full iteration protocol are deferred to later milestones.

## Dependencies
- M1 engine + M2 arrays/strings; Test262 harness; bench gate. ECMA-262 §12–§15.
