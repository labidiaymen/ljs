# Spec 090 — Destructuring-assignment IteratorClose + evaluation order (§13.15.5, §7.4.11)

Status: Done — expressions/assignment/dstr 598→640/640, statements/for-of 1351→1393; language
41,412 → ~41,500 (+~88), 0 regressions vs baseline, 0 panics, bench unchanged.
Owner: Aymen

## Problem (array destructuring ASSIGNMENT `[ … ] = iterable`)

1. **Evaluation order inverted.** The array-pattern loop stepped the iterator (`next()`) *before*
   evaluating each element's AssignmentTargetReference. Per §13.15.5.5/§13.15.5.4 the LHS reference
   (its side-effecting base object / computed key) must be evaluated **first**, then the iterator is
   stepped. So `[ {}[thrower()] ] = it` must throw before any `next()` (`nextCount === 0`) and then
   IteratorClose.
2. **`assign_pattern` element rejected at parse.** `[ {} = yield ]` (a nested pattern target carrying
   a default), refined by the cover grammar into an `assign_pattern` node, wasn't accepted by
   `validateAssignmentTarget` (→ parse_error) and had no runtime handling.
3. **Wrong IteratorClose completion precedence.** On an abrupt element completion the code always used
   the throw-completion close (which swallows a throwing / non-object `return()`). Per §7.4.11, when
   the original completion is a `return`/`break`/`continue` (e.g. the element-ref `yield` producing a
   return via `iter.return()`), a throwing or non-Object `return()` must **propagate** and mask the
   original — not be swallowed.

## Fix (subsystem modules)

- `interpreter.zig`: named types `AssignRef` (a resolved per-element LHS reference captured
  pre-step) + `AssignRefOrAbrupt`.
- `interp_destr.zig`: rewrote the array-pattern loop in `assignPattern` to evaluate each element/rest
  target reference *before* stepping the iterator; added `evalElementRef`, `putElementRef` (apply
  default + PutValue, or recurse for a nested pattern), `elementDefault` (extract `= default`, incl.
  the `assign_pattern` case), and `destrCloseAbrupt` (§7.4.11 close with correct throw-vs-return
  completion precedence).
- `parse_expr.zig`: `validateAssignmentTarget` accepts an `assign_pattern` element, refining its
  target side.

## Acceptance

- `[ {}[thrower()] ] = it` → throws from the target ref before `next()` (`nextCount===0`), then
  `return()` called once with `this`=iterator, 0 args.
- `[ a, b ] = it` where `b`'s setter throws → `return()` called once; a throwing `return()` is
  swallowed when the original completion is the element throw.
- A `return`-completion (element-ref yield) whose `return()` throws → the close error propagates.
- 0 regressions vs `baseline/language.json`; bench no ljs-vs-self regression.

## Out of scope
- The remaining for-of fails (resizable-buffer-backed typed arrays, `iterator-next-reference`,
  `scope-head-lex`) — unrelated.
