# Spec 091 — Async generators: yield* delegation + async-function-expr IIFE (§27.6, §14.4)

Status: Done — language 41,500 → 41,526 (+26), 93.4%, 0 regressions, 0 panics, bench ok.
Owner: Aymen

## Fixes
- **`async function`/`async function*` EXPRESSION as a PrimaryExpression** (`parse_expr.zig`): it was
  parsed at the assignment level and returned early, so `(async function*(){…}())` / `(async
  function(){}())` IIFEs (call inside the parens) were parse errors. Moved recognition into
  `parsePrimary` so trailing Member/Call suffixes attach.
- **`yield*` in an async generator** (`interp_async.zig`, §27.6.3.8 AsyncGeneratorYield / §14.4.14):
  (1) a `.return` resumption at the `yield*` re-yield is forwarded to the inner iterator's `return`
  (not an immediate unwind); a not-done inner return result re-yields and keeps delegating.
  (2) the re-yield no longer double-awaits the inner value (`doAsyncYieldRaw(value, await_first)`),
  so a Promise from a manual async iterator passes through unwrapped.
  (3) a `.return(v)` resumption of a plain async `yield` now `Await(v)`; and `Await(received.value)`
  when the inner iterator has no `return` method (§27.6.3.8 step 7.c.iii).
- **Promise resolve/reject functions report `length: 1`** (`object.zig`, §27.2.1.3) — observable when
  a yielded thenable's `then` receives them.

## Out of scope
- The precise tick/log-order `yield-star-{async,sync}-{next,throw}` accounting tests (functional
  order already correct).
