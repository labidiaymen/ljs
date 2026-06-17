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

## Cycle 8 — US8 Remaining operators (DONE — conformance 26.4% → 26.8%, +55)
- [x] M3-T080 Comma/sequence operator (`a, b` → evaluate both, yield right); `void` (eval operand, yield undefined); `delete` (property/index target → remove own prop, return bool; non-reference → true). Covers `comma/*`, `void/*`, `delete/*`.
  - **Lexer:** added `kw_void` / `kw_delete` keywords (the `comma` token already existed).
  - **Comma (§13.16):** a new `parseExpression` (sequence) layer wraps `parseAssignment` and left-associates `comma` AST nodes. Wired in EXACTLY three full-*Expression* positions: the expression-statement branch of `parseStmt`, the parenthesized-primary `.lparen` case in `parsePrimary`, and the `for(init; test; update)` clauses. Arg/element/param/declarator/object-property comma lists keep `parseAssignment`/`parseSpreadable` untouched — `f(1, 2)`, `[1, 2]`, `var a=1, b=2`, `{a:1, b:2}` are AssignmentExpression lists, not sequences. The arrow cover-grammar is unaffected: `parseAssignment`'s `( … ) =>` lookahead fires before `parsePrimary` ever sees the `(`, so `(a, b) => …` parses as params while `(a, b)` is a sequence. Interpreter: `comma` evals left (discarding its value), then yields right.
  - **`void` (§13.5.2):** new `UnaryOp.void_` — eval operand for side effects, yield `undefined`.
  - **`delete` (§13.5.1):** new `UnaryOp.delete_` handled before the generic value-evaluating unary path (it operates on a Reference). `evalDelete`: `a.b`/`a[k]` → resolve base, `deleteProperty` removes the own prop (`properties.remove(key)`) and returns `true`; an array integer index leaves a hole by writing `undefined` (M-subset; no sparse-array model). A non-Reference operand (`delete 5`, `delete f()`, `delete (x+1)`) evals for side effects and returns true. An unqualified identifier returns true in sloppy (binding not actually removed — benign M-subset deviation). `kw_void`/`kw_delete` added to `isKeywordName` so they stay valid property names.
  - **Regression hunt (net +55 by `passed`; recoveries 189 > regressions 134, no true semantic break):** the new `void {…}` / `0, {…}` prefixes made previously-unparseable object-accessor sources reachable, exposing the §13.2.5.1 accessor-arity Early Error: a getter has an empty parameter list, a setter has exactly one PropertySetParameter (a default `set x(v=1)` is allowed, a rest `set x(...v)` is not). Added that check (recovered `getter-param-dflt` etc.). The 124 `unexpected_error` "regressions" are harness-prelude positives the bare gate can't pass either way; the 10 `no_error_expected_throw` are the still-deferred strict-mode gap (`eval`/`arguments` as a setter param, a `"use strict"` directive inside an accessor body, the `async (x=0,x)=>` async-arrow) — now reachable, not new semantic breaks. Bench green (loop_mix -6.9%, loop_sum -4.7%, str_build -10.2%; ljs ≤ Node; the sequence layer adds one parse-time indirection, not an eval-hot-path cost).
  - **Known gaps:** (1) `delete` of an unqualified identifier doesn't actually remove the binding and doesn't enforce the §13.5.1.1 strict-mode SyntaxError (no strict-mode context propagation — same gap as Cycles 5/6). (2) Array index `delete` writes `undefined` rather than producing a true sparse hole. (3) The strict-mode binding/directive Early Errors above remain deferred.

## Cycle 9 — US9 Strict-mode context + Early Errors (DONE — conformance 26.8% → 27.2%, +69 net)
- [x] M3-T085 Thread strict-mode through the parser (`"use strict"` directive prologue in scripts/functions, lexically inherited by nested functions/arrows). Enforce the strict-only Early Errors that newly-parseable syntax exposed: §13.1.1 reserved / `eval` / `arguments` / future-reserved BindingIdentifier restrictions (params, `let`/`const`, catch param, arrow params), §13.5.1.1 `delete` of an unqualified reference is a SyntaxError, duplicate-param in strict / non-simple param lists. Recovers the strict-mode negatives deferred in Cycles 5/6/8 (`arrow-function/syntax/early-errors/*`, `object` identifier-shorthand-strict, accessor `eval`/`arguments` params, etc.).
  - **Mode wiring:** `engine.evaluateWithLimit` now threads the ignored `mode` into `Parser.parseMode(arena, src, mode == .strict)` (was `_ = mode`). The Test262 runner runs each test in both modes (`runner.zig` passes `engine_mode` *and* prepends `"use strict";`), so strict RunMode now starts the Script in strict context; an explicit directive prologue is detected independently.
  - **Strict context (§11.2.2):** new `Parser.strict: bool` field. `parseProgram` sets it from a token-level directive-prologue scan (`directivePrologueIsStrict`) OR the incoming RunMode. `parseFunction`/`finishArrow`/`parseMethodBody` save+restore `self.strict` around each body, set to `enclosing_strict OR body_has_use_strict` (lexical inheritance — never un-strict inward). The directive scan compares the *raw lexeme* (`"use strict"` / `'use strict'`), so an escaped `"use strict"` does NOT trigger strict; a string used as an operand (`"use strict" + ""`, `("use strict")`) is correctly not a directive (next-token / newline_before boundary check).
  - **Early Errors (all SyntaxError at parse):** §13.1.1 `eval`/`arguments`/future-reserved (`implements interface let package private protected public static yield`) BindingIdentifier in strict — `parseDecl` (recurses through binding patterns), function/arrow/method params (`paramsHaveStrictReserved`/`patternHasStrictReserved`), function name, catch param. §13.15.1 / §13.4.1.1 assignment + prefix/postfix-update target of `eval`/`arguments` in strict. §13.5.1.1 `delete` of a bare identifier in strict (member/index deletes stay legal). §15.1.1 duplicate params in a strict normal function (arrows/methods already enforced this in every mode; the non-simple-param `"use strict"` error from Cycle 4 is kept).
  - **Conformance:** passed 4542 → 4611 (+69 net), **0 true regressions** (mode+path comm), 69 recoveries — 63 strict + 6 sloppy. The 6 sloppy are `function/param-*-strict-body-*` + `object/setter-param-*-strict-inside` (a `"use strict"` directive *inside* the body → strict in both modes, now correctly detected even in sloppy RunMode). Recovery dirs match the deferred gaps exactly: `compound-assignment` (23), `function` (10), `arrow-function/syntax/early-errors` (7), `logical-assignment` (6), `object` (5), `assignmenttargettype`/`prefix-*`/`postfix-*`/`delete`/`assignment`. Bench green (loop_mix -12.1%, loop_sum -4.1%, str_build -3.2%; ljs ≤ Node — strict detection is parse-time only, no eval-hot-path cost).
  - **Known gaps:** strict-mode *runtime* semantics (a sloppy `delete` of a binding still returns true without removing it; assignment to an undeclared name; `this` defaulting) are unchanged — this cycle is parse-phase Early Errors only. Class names (deferred, classes still parse-rejected) and `with`/octal-literal strict errors are out of scope.

## Close (DONE — M3 milestone closed)
- [x] M3-T090 Record conformance baseline (SC-001); README/roadmap; bench green; no M0/M1 regression.
  - **SC-001 ACTUAL vs TARGET — target ≥35%, reached 27.2% (NOT MET).** M3 moved
    `language/expressions` from **23.3% → 27.2%** (bare gate, no harness prelude: passed
    4611 / failed 12360 / skipped 2244 of 19215, commit 1715818) across 9 cycles
    (operators, templates, spread/rest, destructuring, arrows, object sugar + `?.`/`??`,
    assignment operators, comma/void/delete, strict-mode context + Early Errors). The
    `parse_error` bucket dropped substantially as intended, but the headline 35% was not
    reached because the largest remaining levers are **out of M3's scope (parser/syntax)**:
    - **Classes** are the single biggest lever — **2405 unique failing `class/*` test files
      (≈4762 strict+sloppy executions, ≈39% of all `language/expressions` failures)**. Classes
      are deliberately parse-rejected today (Cycles 5/6: `class`/`super` reserved + rejected,
      §15.7) and belong to a dedicated **M4+ classes** milestone, not M3.
    - **Generators / async** (`function*`, `yield`, `async`/`await`) add ≈1067 + ≈767 more
      failing executions — also separate later milestones (iteration protocol, async).
    Honest read: M3 cleared the syntax/`parse_error` bottleneck it was scoped for; crossing
    35% requires **classes first** (the ≈39% failure share above), which is M4 work, not a
    shortfall in M3 syntax coverage.
  - **SC-002 (≥40 syntax unit tests):** met — operator/template/spread/destructuring/arrow/
    object-sugar/assignment/comma-void-delete/strict tests across the 9 cycles, all green via
    `zig build test`.
  - **SC-003 (M0/M1/M2 + bench + leaks):** met — `zig build test` exit 0 (no M0/M1/M2
    regression), `zig build bench` = "perf: ok (no ljs-vs-self regression)" (ljs 0.3–0.5× Node),
    no leaks under the testing allocator.
  - **Baseline recorded:** `baseline/language-expressions.json` (4611 passing `<file>#<mode>`
    ids, bare-gate metric) via `ljs-test262 --path … --update-baseline …`; the `--baseline`
    regression gate passes (exit 0, "conformance: ok (no regression vs baseline)").

## Dependencies / order
Ordered by impact-to-effort: operators first (cheap, common), then template literals, then the
bigger structural features (spread/destructuring/arrow), then object-literal sugar + access ops.
Each cycle bench-gated.

---

## Conformance Loop Ledger (M62+) — lightweight milestone tracking

Post-M3 work is **conformance-discovered** (run Test262 → chase the failure cluster →
implement one coherent spec-clause fix → full gate → commit), not pre-planned per-feature
folders. This ledger is the running record: one checked line per milestone with the spec
clause + test delta. Each line = one commit, all gates green (build/test/lint/conformance
0-regression/bench). `language/` metric = passed / (total − skipped).

- [x] **M62** RegExp literals re-enabled at lexer + `validateLiteral` (§12.9.5) — 87.0%→87.8%
- [x] **M63** Symbol-keyed property reflection (hasOwnProperty/propertyIsEnumerable, §20.1.3) — 87.8%→88.0%
- [x] **M64** destructuring catch parameters (§14.15) — 88.0%→88.4%
- [x] **M65** global/sloppy `this` binding + strict [[Set]]/delete throwing (§10.2.1.2/§9.4.2) — 88.4%→88.7%
- [x] **M66** named function expression self-binding (§15.2.5) — 88.7%→88.8%
- [x] **M67** derived-ctor `this` TDZ via per-binding cell + lexical arrow super/home (§13.3.7) — 88.8%→88.9%
- [x] **M68** mapped `arguments` [[ParameterMap]] bidirectional aliasing (§10.4.4) — 88.9% (+29)
- [x] **M69** strict/unmapped `arguments.callee` %ThrowTypeError% poison (§10.4.4.6) — 88.9% (+7)
- [x] **M70** for-in/of lexical duplicate binding-name early error (§14.7.5.1) — 88.9%→89.0% (+8)
- [x] **M71** `var` hoisting to the VariableEnvironment (§10.2.11/§16.1.7/§14.3.2.1) — 89.0%→89.3%
  (+157). First milestone under FULL SDD: see `specs/059-var-hoisting/`. (From here, each milestone
  gets its own `specs/NNN-<slug>/` spec folder; this ledger remains a compact index.)
- [x] **M72** SuperProperty as assignment/update target (§13.3.5/§6.2.5.6/§10.1.9.2) — 89.3%→89.4%
  (+12). `specs/060-super-property-write/`.
- [x] **M73** class constructor [[Call]] guard on every entry path (call/apply/bind) (§15.7.14) —
  89.4% (+4). `specs/061-class-ctor-call-guard/`.
- [x] **M74** class heritage `prototype` validation (§15.7.14) — 89.4% (+6).
  `specs/062-class-heritage-prototype-validation/`.
- [ ] **M75 (next, bigger):** built-in subclassing exotic instances (`class S extends Array{}` →
  `new S(3).length`) — construct-model rework: super() must create the exotic `this`. Array first.
- [ ] Async/Promise/microtask family (~325 tests; also the Node bridge)
- [ ] Class runtime-semantics long-tail (private methods/#x-in, static blocks, field-init order)
- [ ] **Target: language 93%** (currently 89.4%, need ~+1590)
