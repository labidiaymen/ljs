# Spec 097 — Statement completion values + UpdateEmpty (§6.2.4, §13–§14)

Status: Done — statements/switch 169→207; language 42,187 → ~42,300 (+~110), 94.9% → 95.1% (crosses
95%!), 0 regressions vs baseline (after a TLA follow-up fix), 0 panics, bench ok. Owner: Aymen

## Problem
The `Completion` type had no *empty* `[[Value]]`, and `break`/`continue` carried only a target label,
no value. So §6.2.4.6 UpdateEmpty was never applied: declarations returned `normal:undefined`
(clobbering a prior value), and `break`/`continue` lost the accumulated block value. The ~89 `cptn-*`
Test262 cases (across switch, loops, if, try, labeled, blocks, …) check `eval("…")`'s completion value
and failed.

## Fix
- `completion.zig`: added an `.empty` variant (a normal completion with empty `[[Value]]`); `brk`/`cont`
  carry `Abrupt{ label, value: ?Value }` (null = still-empty); `updateEmpty(v)` + `isAbrupt` (treats
  `.empty` as non-abrupt).
- `interp_stmt.zig`: every StatementList / CaseBlock / loop threads a running `V` — a `.normal`
  replaces V, `.empty` keeps it, an abrupt completion returns `UpdateEmpty(result, V)` so break/continue
  carry the accumulated value; `if`/`with`/`try` wrap in `UpdateEmpty(C, undefined)`; labeled-break
  unwrap preserves the value. A StatementList does NOT fill an abrupt completion's empty value when its
  own V is still empty (so the enclosing switch/loop accumulator supplies it).
- `interpreter.zig`/`engine.zig`/`interp_async.zig`/`interp_expr.zig`/`interp_module.zig`: handle the
  new `.empty` variant in exhaustive completion switches.
- max_depth 400→300 + loop/switch bodies extracted from the hot `evalStmt` frame, so the `tco-*`
  100k-deep recursion throws a catchable RangeError instead of overflowing the native stack (panic).

## Follow-up fix (this integration)
The async-MODULE body statement loop (`runGeneratorBody` `module_run`) treated the new `.empty` as
abrupt (`else => return last`), exiting after the first statement — so a top-level-await module
(`var x = await …; … $DONE();`) never reached `$DONE` (14 `module-code/top-level-await` regressions).
Fixed: `.normal, .empty => {}` continues the body. TLA dir 201→215.

## Out of scope
- `tco-*` (proper tail calls).
