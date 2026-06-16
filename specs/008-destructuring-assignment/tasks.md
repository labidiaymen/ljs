---
description: "Task list for M7 — destructuring assignment (§13.2.4 / §13.2.5.1 / §13.15.1 / §13.15.5, conformance-driven)"
---

# Tasks: M7 — Destructuring Assignment

**Metric:** conformance is reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`, the standard Test262 way), same as M4–M6. The continuity gate is
`language/expressions`; the committed baseline `baseline/language-expressions.json` (M6 close: passed
**6509**, **38.4%**) is the floor — M7 must hold it and push it UP (≈1000 `assignment/dstr` +
`object/dstr` tests were `parse_error` at HEAD).

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + **bench (ljs ≤ Node)**
green). Re-measure `language/expressions` (continuity gate) each cycle.

**Mandatory regression hunt (every cycle):** the cover-grammar refinement touches `parseAssignment`
(used on every assignment / array element / call arg / property value / declarator / RHS) → engine-wide
risk. Capture the per-test result set (by `mode+path`) before and after (`git stash` the worktree,
rebuild ReleaseFast, `--update-baseline` to a JSON pass-id set, `comm`); true-regressions must be 0 or
far outweighed by recoveries. Do NOT commit a net regression on the continuity gate.

## Cycle 1 — array + object destructuring assignment + cover-grammar early errors (US1+US2+US3+US4) 🎯 (DONE — continuity gate (`language/expressions`, harness): passed 6509 → **6718** (+209), **0 true regressions / 209 recoveries** by `mode+path`; conformance 38.4% → **39.6%**. Recoveries by path: **167 `assignment/dstr`** (the core lever — the whole subtree was `parse_error`), 16 `class/dstr`, 4 each `object`/`function`/`arrow-function` `dstr`, 2 `assignment/destructuring`, + 16 array-literal-elision tests (`array/S11.1.4_A1.*`, `array/11.1.4-0.js` — array holes `[1, , 3]` now parse). `assignment/dstr` subtree itself 46.6% (298/640). Bench green: `perf: ok (no ljs-vs-self regression)`, ljs 0.2–0.5× Node (loop_mix −6.5% / loop_sum +1.7% / str_build −10.6% vs base, all `ok` — the refinement is parse-time and `assignPattern` never runs in the hot loop). Committed baseline bumped 6509 → 6718.)
- [x] M7-T010 **AST (`src/ast.zig`)** — new `Node.assign_pattern: {target, value}` (§13.15.5; `target` is
  the cover-grammar ArrayLiteral/ObjectLiteral node, refined in place — the interpreter walks the literal
  as a pattern). New `Node.elision` (§13.2.4 array hole; as a literal element → `undefined`, as a pattern
  element → skipped position). `Property` gains an optional `default` (§13.2.5.1 shorthand
  CoverInitializedName `{x = d}`). `containsArguments` extended for the two new nodes + `Property.default`.
- [x] M7-T020 **Parser — literals tolerate the cover-grammar forms (`src/parser.zig`)** — the array-
  literal arm of `parsePrimary` accepts elisions (`[a, , b]` / `[, x]`) and folds an element's `= default`
  tail into an `assign*` node (right-recursive `parseAssignment`; in a real literal `[a = 1]` ≡ `[(a = 1)]`,
  when refined the `=` becomes the element default). A trailing comma after a spread (`[...x,]`) is
  recorded as a trailing `elision` (valid literal — no extra element; the interpreter drops it — but marks
  the refined AssignmentRestElement non-last). The object-literal parser records a shorthand `{x = d}`
  default and increments a §13.2.5.1 CoverInitializedName obligation counter (`self.cover_init`).
- [x] M7-T030 **Parser — cover-grammar refinement (`parseAssignment`)** — when the parsed `left` is an
  (un-parenthesized — `last_was_paren` false, §13.15.1 a ParenthesizedExpression is AssignmentTargetType
  *invalid*) ArrayLiteral/ObjectLiteral followed by a plain `=` (not compound), `validateAssignmentPattern`
  refines it to an AssignmentPattern and the result is an `assign_pattern` node. `validateAssignmentPattern`
  / `validateAssignmentTarget` (§13.15.5.1) validate every leaf (identifier / member / index / private
  member / `assign*`-with-default / nested literal pattern), enforce the §13.15.5.1 rest rules (array rest
  last + no default; object rest last + simple target), reject non-assignable leaves, and discharge the
  CoverInitializedName obligations. `parseStmt` checks the per-statement `cover_init` residue → an
  un-refined `{x = d}` (`({x = 1});`, `f({a = 1})`) is a SyntaxError.
- [x] M7-T040 **Interpreter — `assignPattern` (`src/interpreter.zig`, §13.15.5.2–.5)** — parallel to
  `bindPattern` but for assignment: `evalExpr` `.assign_pattern` evaluates the RHS once, runs
  `assignPattern`, yields the RHS value. Array branch pulls positionally from `iterableToSlice` (Arrays/
  Strings), skips elisions, collects a rest into a fresh Array, applies defaults; object branch reads each
  property (getters run), applies the shorthand/folded default, collects an object rest of remaining own
  enumerable props. Each leaf routes through `assignElement` (strips a folded `= default` and assigns the
  reference inline — identifier env assignment / member-index setProperty / private setPrivate) →
  `assignTargetNode` (a nested array/object literal recurses; otherwise `assignToTarget`). `assignToTarget`
  gained a `private_member` target arm (`[obj.#x] = …`). `evalExpr` `.elision` → `undefined`; the array-
  literal evaluator drops a trailing-elision-after-spread so `[...x,]` adds no element.
- [x] M7-T050 **Tests (`src/engine.zig`, all green — 14 added across 4 test blocks)** — array targets
  (basic / yields-RHS / swap / hole `[, a]` + `[a, , c]` / rest / defaults / member+index target / String
  iterable); object targets (shorthand / rename / member-value `{x: o.p}` / default `{x = 9}` / rest /
  null-throws); nested (`[[a], {b}]`, `{p: [a, b]}`, `[{x: y = 9}]`); cover-grammar early errors
  (`({x = 1})` / `f({a = 1})` / `[1] = x` / `({a: 1} = {})` / `[a()] = [1]` all SyntaxError; `[1, , 3]`
  literal length 3 — no regression).
- [x] **Conformance + regression hunt (harness, ReleaseFast, `git stash` HEAD vs working-tree `comm`):**
  continuity gate `language/expressions` `passed 6509 → 6718` (+209), 38.4% → **39.6%** — **0 true
  regressions / 209 recoveries** by `mode+path`. The before set was verified to equal the committed
  baseline + the true HEAD pass-set before diffing. The first regression pass surfaced 12 destructuring
  negatives that newly *parsed* (so they had "passed" at HEAD only because the construct failed to parse):
  fixed by adding the §13.15.1/§13.15.5.1 early errors — parenthesized-literal target (`({}) = 1`,
  `() => ({}) = 1`, `([a]) = 1`), AssignmentRestElement non-last/`[...x,]` + rest-default `[...x = 1]`,
  AssignmentRestProperty non-last `{...rest, b}` — driving true regressions to **0**. Bench green. Committed
  baseline bumped 6509 → 6718.
- [x] **Landed:** array + object destructuring assignment (holes, defaults, rest, nested,
  member/index/private targets, swap-correct single RHS eval, yields-RHS-value); the §13.15.5
  cover-grammar refinement in `parseAssignment` (un-parenthesized literal → `assign_pattern`); the
  §13.2.5.1 CoverInitializedName + §13.15.5.1 rest-placement / non-assignable-leaf / parenthesized-literal
  parse-phase early errors; array-literal elisions (`[1, , 3]`). **Deferred (future cycles):** the full
  iterator protocol for array assignment patterns (`Symbol.iterator`, iterator-close on abrupt completion,
  generator/`yield` targets) — the dominant remaining `assignment/dstr` + `object/dstr` failures need it;
  computed keys in object assignment patterns beyond ToString; strict-mode `eval`/`arguments` target
  restrictions already covered by the existing `last_was_paren`/`isEvalOrArguments` guards.

## Dependencies / order
Cycle 1 lands the whole §13.15.5 surface in one slice (the cover-grammar refinement + `assignPattern` are
inseparable — the parser can't refine without an evaluator to run, and the early-error set is what keeps
the refinement from net-regressing the negatives). Future cycles, if pursued, layer the full iterator
protocol underneath the array-pattern path (shared with for-of / spread) to recover the iterator-close /
generator `assignment/dstr` + `object/dstr` remainder. Each cycle bench-gated (parse-time change; the
hot loop never touches `assignPattern`) and runs the before/after `mode+path` regression hunt.
