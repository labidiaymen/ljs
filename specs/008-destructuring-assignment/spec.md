# Feature Specification: M7 — Destructuring Assignment

**Feature Branch**: `008-destructuring-assignment`

**Created**: 2026-06-16

**Status**: Cycle 1 done

**Input**: "M7: destructuring assignment. A ~1000-test lever — `assignment/dstr/*` (≈509 files) and
`object/dstr/*` (≈522 files) currently fail with `parse_error` because destructuring *assignment* (an
array/object literal as the target of `=`, §13.15.5) is not parsed. M3 Cycle 4 implemented destructuring
in DECLARATIONS and PARAMS (`var [a,b] = x`, `function f({x}){}`) via a recursive `bindPattern`; what was
missing is the *assignment* form: `[a, b] = arr;`, `({x, y} = obj);`, holes `[a, , b]`, rest
`[a, ...rest]` / `({x, ...rest})`, defaults `[a = 1]` / `({x = 1})`, nested `[{a}, [b]]`, and
member/index targets `[obj.a, arr[0]] = x` / `({p: obj.a} = o)`."

## Why (data-driven)

At M6 close the continuity gate (`language/expressions`, harness metric) is **6509 / 38.4%**. The single
largest remaining `parse_error` cluster on that subtree is destructuring **assignment**: an
ArrayLiteral/ObjectLiteral used as the LHS of `=`. M3 Cycle 4 built the binding-side machinery
(`Pattern`/`BindingElement`, recursive `bindPattern`) for *declarations* and *parameters*, but the
assignment form is a different production — §13.15.5 DestructuringAssignmentEvaluation, which uses a
**cover grammar**: the LHS is parsed as an ordinary expression and, when followed by `=`, **refined** to
an AssignmentPattern. The leaves of an assignment pattern are not new bindings but existing references
(identifier / `a.b` / `a[k]` / nested pattern), so the evaluator must PUT into a reference rather than
declare. Implementing the refinement + a parallel `assignPattern` unblocks the whole `assignment/dstr`
subtree (and the assignment-shaped cases in `object/dstr`, `class/dstr`, `function/dstr`,
`arrow-function/dstr`).

The refinement touches `parseAssignment` — used on every assignment expression, every array element,
call arg, property value, declarator, and RHS — so the regression risk on ordinary assignment / arrow
heads / object literals is real, and the before/after `mode+path` diff is mandatory.

## User Scenarios & Testing *(mandatory)*

Users: engine devs / CI. Each cycle adds a coherent slice of §13.15.5, re-measures `language/expressions`
(the continuity gate — must not regress), runs the mandatory before/after regression hunt by `mode+path`
(the `parseAssignment` cover-grammar change is engine-wide → true regressions must be 0 or far outweighed
by recoveries), and stays bench-green (the refinement is parse-time; `assignPattern` runs only for actual
destructuring assignments, never the hot loop).

### US1 — Array destructuring assignment `[a, b] = arr` (§13.15.5.3) (P1)
An ArrayLiteral on the LHS of `=` is refined to an ArrayAssignmentPattern. Elements are pulled
positionally from the iterable (Arrays/Strings, the engine's iterable model): a plain target
(identifier / `a.b` / `a[k]`) is PUT; a hole `[a, , b]` skips a position; `[a = d]` applies the default
`d` when the source value is `undefined`; a trailing `[a, ...rest]` collects the leftovers into a fresh
Array. The whole assignment expression yields the RHS value. Swap `[a, b] = [b, a]` works (the RHS is
evaluated once, before any target is written).
**Test**: `[a, b] = [1, 2]` → `a+b === 3`; `[, a] = [1, 2]` → `a === 2`; `[a, ...b] = [1, 2, 3]` →
`b.length === 2`; `[a = 5] = []` → `a === 5`; `[a, b] = [b, a]` swaps; `var r = ([a,b]=[7,8])` →
`r.length === 2` (yields RHS); `[o.p, arr[0]] = [3, 4]` PUTs into member/index references.

### US2 — Object destructuring assignment `({x, y} = obj)` (§13.15.5.5) (P1)
An ObjectLiteral on the LHS of `=` (only ever parenthesized in statement position — a leading `{` is a
block) is refined to an ObjectAssignmentPattern: shorthand `{x}`, renaming `{x: target}` (target may be a
member/index/nested pattern), CoverInitializedName default `{x = d}` (applied when the property is
`undefined`), and `{x, ...rest}` (remaining own enumerable props copied into a fresh object). A null /
undefined RHS throws a TypeError.
**Test**: `({x, y} = {x:1, y:2})` → `x+y === 3`; `({x: a, y: b} = {x:3, y:4})`; `({x: o.p} = {x:5})` →
`o.p === 5`; `({x = 9} = {})` → `x === 9` (default); `({a, ...r} = {a:1, b:2, c:3})` → `r.b+r.c === 5`;
`({x} = null)` throws.

### US3 — Nested patterns + member/index targets (§13.15.5.1) (P1)
Pattern elements/property-values may themselves be array/object patterns (recurse) or member/index
references. `[{a}, [b]] = x`, `({p: [a, b]} = o)`, `[obj.a, arr[0]] = x`, `({p: obj.a} = o)`.
**Test**: `[[a], {b}] = [[1], {b:2}]` → `a*10+b === 12`; `({p: [a, b]} = {p: [3, 4]})` → `a+b === 7`;
`([{x: y = 9}] = [{}])` → `y === 9` (nested object pattern with a default).

### US4 — Cover-grammar early errors (§13.2.5.1 / §13.15.1) (P1)
The refinement must reject what is not a valid AssignmentPattern, as a **parse-phase** SyntaxError:
a CoverInitializedName `{x = 1}` that is NOT refined (`({x = 1});`, `f({a = 1})`); a non-assignable leaf
(`[1] = x`, `({a: 1} = {})`, `[a()] = x`); a PARENTHESIZED literal `({}) = 1` / `([a]) = 1` (a
ParenthesizedExpression has AssignmentTargetType *invalid*); an AssignmentRestElement that is not last or
carries a default (`[...x,]`, `[...x = 1]`); an AssignmentRestProperty that is not last (`{...rest, b}`).
**Test**: each of the above is a SyntaxError; ordinary `{x = 1}`-free object literals, `[a = 1]` array
literals (an ordinary assignment), and array-literal holes `[1, , 3]` (length 3) keep working.

### Edge Cases
- A trailing comma after a spread in an array LITERAL (`[...x,]`) is valid (no extra element) but makes
  the refined AssignmentRestElement non-last → SyntaxError only when used as a pattern. The parser marks
  it with a trailing elision (which literal evaluation drops, so `[...x,]` ≡ `[...x]` as a value).
- `{a: b = 1}` is a legal object literal (`{a: (b = 1)}`), so it is NOT a CoverInitializedName error; only
  the SHORTHAND `{a = 1}` is. When refined, `assignElement` strips the folded `= 1` and applies it as the
  property's destructuring default.
- An object rest target is a simple reference (identifier / member / index), not a nested pattern.
- An array rest target MAY be a nested pattern (`[...[a, b]] = x`).
- The RHS is evaluated exactly once (swap correctness); each leaf is a fresh reference PUT.

## Requirements *(mandatory)*
- **FR-001** (US1–US3): New AST node `assign_pattern: {target, value}` (the `target` is the cover-grammar
  ArrayLiteral/ObjectLiteral node, refined in place) + an `elision` node (array hole). `Property` gains an
  optional `default` for shorthand CoverInitializedName.
- **FR-002** (US1–US4): Parser — array literals tolerate elisions (`[a, , b]`) and fold an element's
  `= default` tail into an `assign*` node (right-recursive `parseAssignment`); object literals record a
  shorthand `{x = d}` default + a CoverInitializedName obligation counter. In `parseAssignment`, when the
  parsed `left` is an (un-parenthesized) array/object literal followed by `=`, `validateAssignmentPattern`
  refines it and the result is an `assign_pattern` node.
- **FR-003** (US4): The §13.2.5.1 CoverInitializedName obligation (a `{x = d}` that is not refined) is a
  parse-phase SyntaxError, tracked by a per-statement counter discharged by the refinement; the
  parenthesized-literal, non-assignable-leaf, and rest-placement/rest-default early errors likewise.
- **FR-004** (US1–US3): Interpreter — `assignPattern` (parallel to `bindPattern`, §13.15.5.2–.5): evaluate
  the RHS once, then for each leaf resolve the TARGET as a reference and PUT (identifier → env assignment
  with const/TDZ checks; member/index → setProperty; nested pattern → recurse). Defaults apply when the
  source value is `undefined`. Array patterns reuse the existing iterable model; object rest copies
  remaining own enumerable props. The assignment expression yields the RHS value.
- **FR-005**: Spec-clause citations on every new AST node / parser refinement / interpreter operation
  (§13.2.4 Elision, §13.2.5.1 CoverInitializedName, §13.15.1/§13.15.5.1 refinement + early errors,
  §13.15.5.2–.5 DestructuringAssignmentEvaluation).
- **FR-006**: ljs ≤ Node on the bench (absolute pre-commit gate); the refinement is parse-time and
  `assignPattern` runs only for actual destructuring assignments — the ordinary-assignment / loop hot
  path MUST NOT regress > 15%.
- **FR-007**: No net regression on the continuity gate (`language/expressions`, harness metric): true
  regressions by `mode+path` must be 0 or far outweighed by recoveries.

## Success Criteria *(mandatory)*
- **SC-001**: `language/expressions` `passed` (harness metric) ≥ the M6-close baseline of 6509 (38.4%).
  [Cycle 1 result: **6718 (+209), 39.6%** — 0 true regressions / 209 recoveries by `mode+path`; committed
  baseline bumped 6509 → 6718.]
- **SC-002**: The `assignment/dstr` subtree recovers substantially (it was ~all `parse_error`); the
  assignment-shaped cases in `object/dstr` / `class/dstr` / `function/dstr` / `arrow-function/dstr` and
  the array-literal-elision tests (`array/S11.1.4_A1.*`) recover too. [Cycle 1: `assignment/dstr`
  46.6% (298/640); recoveries 167 `assignment/dstr`, 16 `class/dstr`, 4 each `object`/`function`/
  `arrow-function`/`dstr`, 2 `assignment/destructuring`, + the array-elision literal tests.]
- **SC-003**: ≥12 destructuring-assignment unit tests pass (`zig build test` exit 0): array (basic /
  yields-RHS / swap / hole / rest / default / member+index target / String iterable); object (shorthand /
  rename / member-value / default / rest / null-throws); nested; the cover-grammar early errors.
- **SC-004**: M0–M6 tests still green; lint 0/0; bench green (ljs ≤ Node, no hot-path regression); no net
  regression on the `mode+path` diff (FR-007).

## Assumptions
- Tree-walk tier retained; this is parser-refinement + one new evaluator path. The iterable model for
  array assignment patterns is Arrays + Strings (matches `bindPattern`/spread); the full iterator
  protocol (`Symbol.iterator`, iterator-close on abrupt completion, generators) is deferred — the
  remaining `assignment/dstr` failures need it.
- §13.15.5.1 early errors are the common set (non-assignable leaf, parenthesized literal, rest
  placement/rest-default, CoverInitializedName); the full ValidateAndApply-style matrix is M-subset.
- `({...} = ...)` only appears parenthesized (a leading `{` in statement position is a block); the
  existing parens path handles it.

## Dependencies
- M3 parser/spread/arrow cover-grammar (`parseAssignment`, `parsePattern`, the `last_was_paren` flag),
  M3 Cycle 4 binding-side destructuring (`Pattern`/`bindPattern`/`iterableToSlice`), M4 object model
  (members/index/private/accessors), M6 enumerability (object rest copies own enumerable props). Test262
  harness; bench gate. ECMA-262 §13.2.4, §13.2.5.1, §13.15.1, §13.15.5.
