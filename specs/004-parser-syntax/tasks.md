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

## Cycle 4 — US4 Destructuring (DONE — conformance 25.3% → 25.7%, +72)
- [x] M3-T040 Array/object binding patterns in `var`/`let`/`const` + params (with defaults/holes/rest + nesting). New AST `Pattern` union (identifier/array/object) with `BindingElement` (optional default, holes as null target) and `Param` (pattern + default); `Declarator.target` and `FunctionData.params` now carry patterns. Parser: `parsePattern`/`parseArrayPattern`/`parseObjectPattern`, pattern-aware `parseDecl`/`parseParams`. Interpreter: one recursive `bindPattern` (shared by declarations + `[[Call]]` param binding) with fast paths for plain-identifier targets/params so the common case pays no matching cost (bench stayed green). Iterable model = Arrays + Strings (matches spread). Object rest copies remaining own props.
  - **Regression hunt (net was −4 before fixes):** newly-parseable `function/dstr/*` tests reached the `assert.throws` harness path, which references the global `undefined` (and `NaN`/`Infinity`) — previously unbound → they threw `ReferenceError`. Added the §19.1 global value properties `undefined`/`NaN`/`Infinity` (immutable), recovering them + many others. Also added two Early Errors my parser newly exposed: §14.3.1.1 a BindingPattern (or any `const`) declaration requires an initializer (`let {x};` is a SyntaxError), and §15.1.1 a "use strict" directive is forbidden with a non-simple parameter list. Final: no true regressions (mode+path), +72 net.

## Cycle 5 — US5 Arrow functions (DONE — conformance 25.7% → 25.9%, +30 net)
- [x] M3-T050 `=>` (expr + block body); lexical `this` (capture enclosing `this_val`). Lexer
  `fat_arrow` token (`=>`, distinct from `=`/`>=`) + per-token `newline_before` flag (§12.3, for the
  ASI-restricted production). AST `Function.is_arrow`; expression bodies normalized to a single
  `return expr` so `body` is uniform. Cover-grammar: single-ident `x =>` detected by a 2-token peek
  in `parseAssignment`; parenthesized `( … ) =>` by bounded lookahead (`parenIsArrowHead` scans to the
  matching `)` tracking nesting) then reusing `parseParams`/`parsePattern` — no expression→pattern
  reinterpretation. `FunctionData` gains `is_arrow` + `captured_this` (set to the interpreter's
  `this_val` at creation); `[[Call]]` uses the captured `this` for arrows (bypassing call-site
  rebinding); arrows get no `.prototype` and `new (()=>{})` → TypeError (§15.3). Early Errors
  (§15.3.1): duplicate BoundNames (every mode) and the `[no LineTerminator here] =>` ASI restriction.
  - **Regression hunt (net was −65 before fixes; gate measured WITHOUT `--harness-dir`, so positive
    arrow tests that call `assert.*` can't pass that way — the win shows as +86 *with* the prelude, but
    the bare gate only moves on negatives):** newly-parseable arrow source exposed three real gaps.
    (1) §15.3.1 duplicate-param + ASI-`=>` early errors (recovered ~30). (2) **`class` was lexed as an
    identifier** — `var C = class {…}` parsed as `C = «class»` + a stray block, so class *parse*-negative
    tests (e.g. `arguments`/`super` in an arrow class field) only "passed" at HEAD because the arrow
    inside failed to parse; with arrows working they reached runtime and failed. Fix: reserve `class`
    (`kw_class`) and parse-reject it like `import` (§15.7 unsupported) — spec-correct and recovers the
    28 `class/elements` negatives. Final: +42 recoveries / −12 regressions = **+30 net**.
  - **Known gap:** 12 `arrow-function/syntax/early-errors/*` strict-mode binding restrictions remain
    (`eval`/`arguments`/`yield`/future-reserved-words as a param name → SyntaxError only under
    `[onlyStrict]`). The parser has no strict-mode context propagation yet; deferred (needs a
    strict-aware BindingIdentifier check, not arrow-specific).

## Cycle 6 — US6 Object-literal extensions + access operators (DONE — conformance 25.9% → 26.0%, +19 net)
- [x] M3-T060 Object-literal sugar (§13.2.5): shorthand `{x}`, computed `{[k]:v}`, method shorthand
  `{m(){…}}`, object spread `{...o}` (CopyDataProperties of own enumerable props). Accessors
  (§13.2.5.6): `{get x(){…}}` / `{set x(v){…}}`. Optional chaining `?.` / `?.[]` / `?.()` (§13.3.9,
  whole-chain short-circuit on a nullish base). Nullish coalescing `??` (§13.13) with the §13.13.1
  `||`/`&&` mixing Early SyntaxError.
  - **Object model:** the property map value became a tagged `PropertyValue = { data: Value }` |
    `{ accessor: {get, set} }` (`src/object.zig`). `get` keeps a single-branch data fast path; a new
    `getProp` returns the located descriptor + holder so the interpreter invokes a getter on read
    (`this` = receiver) and a setter on write. Data-property get/set stays a direct path — bench
    held (loop_mix -2.6%, no regression).
  - **Lexer:** `?.` (NOT before a digit — `a?.5:b` stays `?` + `.5`), `??` (left `??=` to US7), and
    reserved `super` (`kw_super`, parse-rejected like `import`/`class`).
  - **Parser:** `parseShortCircuit` layer separates the `||`/`&&` climb from the `??` chain and
    enforces the no-mix Early Error via a `last_was_paren` flag (parenthesizing defuses it).
    `parsePostfix` builds `optional` chain nodes; §13.3.9.1 tail restrictions (`a?.b\`tpl\``,
    `a?.b++`, `++a?.b`) are Early Errors. Methods/accessors get §13.2.5.1 UniqueFormalParameters
    (no duplicate params).
  - **Regression hunt (net was −29 before fixes; gate vs a `--update-baseline` HEAD rebuild):** the
    newly-parseable optional-chain + object-method source reached cases that need stricter parse
    errors. Recovered 18 via the §13.3.9.1 tail restrictions, `super` rejection (the
    `name-super-call-*` method negatives), and method duplicate-param errors. **Known gap (11
    remaining):** 8 `identifier-shorthand-*-invalid-strict-mode` + `11.1.5-1gs` + 2
    `name-param-redecl` need strict-mode binding restrictions / param-vs-`let` redeclaration —
    blocked on the still-deferred strict-mode context propagation (same gap noted in Cycle 5).

## Cycle 7 — US7 Complete assignment operators (DONE — conformance 26.0% → 26.4%, +70)
- [x] M3-T070 Compound assignment for the full operator set: `**= <<= >>= >>>= &= |= ^=` (desugar `x op= v` → `x = x op v`, all three target kinds) + logical assignment `&&= ||= ??=` (short-circuit semantics: only assign when the guard passes). Covers `compound-assignment/*` + `logical-assignment/*`.
  - **Lexer:** 10 new tokens with maximal-munch ordering — `**=` before `**`; `<<=` before `<<`; `>>>=` before `>>>` before `>>=` before `>>`; `&&=` before `&&` before `&=`; `||=`/`??=` similarly. The 7 compound-assign tokens reuse `maybeCompound`; the 3 logical-assign tokens (`&&=`/`||=`/`??=`) needed their own arms.
  - **Compound (§13.15):** extended `compoundBinOp` with `exp`/`shl`/`shr`/`shr_un`/`bit_and`/`bit_or`/`bit_xor` → `parseAssignment` desugars `x op= v` → `x = x op v` for all three target kinds (identifier / member / index), reusing the existing `.assign`/`.assign_member`/`.assign_index` machinery.
  - **Logical (§13.15.2):** NOT a plain desugar. New AST `logical_assign {op, target, value}` keeps the target node intact; a dedicated `parseAssignment` branch (`logicalAssignOp`) validates the target is assignable. Interpreter `evalLogicalAssign` resolves the reference **once** (binding, or base [+key] for member/index — base evaluated once even when no write happens), reads the current value, lets `shouldAssign` decide via the guard (`&&=` truthy / `||=` falsy / `??=` nullish, reusing the Cycle-6 §13.13 null/undefined check), and only THEN evaluates the RHS + writes. Yields the target's final value.
  - **Conformance:** +70 net (passed 4417 → 4487). The bare gate runs without the `assert.*` harness prelude, so most `compound-assignment/*` (~786) / `logical-assignment/*` (~132) positives that call `assert.sameValue` still can't pass that way; the recovered tests are the parse-error → pass conversions (e.g. `*-no-*` / negative-grammar cases) plus the harness-free positives. Bench green (loop_mix -11.5%, loop_sum -2.6%, str_build -8.8% — all ok, ljs ≤ Node). No regression: passed only moved up. No new known gaps.

## Cycle 8 — US8 Remaining operators (deferred from US1)
- [ ] M3-T080 Comma/sequence operator (`a, b` → evaluate both, yield right); `void` (eval operand, yield undefined); `delete` (property/index target → remove own prop, return bool; non-reference → true). Covers `comma/*`, `void/*`, `delete/*`.

## Close
- [ ] M3-T090 Record conformance baseline (SC-001, target ≥35%); README/roadmap; bench green; no M0/M1 regression

## Dependencies / order
Ordered by impact-to-effort: operators first (cheap, common), then template literals, then the
bigger structural features (spread/destructuring/arrow), then object-literal sugar + access ops.
Each cycle bench-gated.
