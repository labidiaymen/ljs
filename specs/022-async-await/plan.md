# Plan: async / await (minimal sound subset)

## Approach

Lower `Promise<T>` to a heap object and run the program on a small, real event
loop. Avoid a coroutine transform: an `async` function compiles to an ordinary
Zig function returning `*LumenPromise(T)`, and `await p` drives the loop until
`p` is resolved, then reads `p.value`. This is sound for the supported cases
(immediately-resolved promises and timer-resolved promises) and deterministic.

### Lexer
- No new tokens. `async` / `await` / `setTimeout` are identifiers handled in the
  parser; `Promise<T>` flows through the existing generic annotation path.

### AST
- `FunctionDecl`: add `is_async: bool`.
- `Expr`: add `await_expr: *Expr` for `await <expr>`.
- `Program`: add `needs_async: bool` to gate the runtime prelude.

### Parser
- `parseStmt`: an `async` keyword before `function` sets `is_async`.
- `parseUnary`: a leading `await` parses the operand and wraps it in `await_expr`.
- `setTimeout(cb, ms)` parses as an ordinary `call`; `Promise.resolve(v)` parses
  as a `static_call` with namespace `Promise` (added to `isStdNamespace`).

### Types
- Add `promise_type: *const Type` to the `Type` union.
- `zigName(Promise<T>)` -> `*LumenPromise(<T>)`; `mangle`/`same`/`toAnnotation`
  handle it.

### Checker
- `typeFromAnnotation`: `Promise<T>` -> `.promise_type` (1 type arg required).
- `declareFunction`: when `is_async`, require the return type to be a
  `promise_type` (`E_ASYNC_RETURN`).
- `checkFunctionBody`: while checking an `async` body, set a flag and treat
  `return v` as checking `v` against the promise's inner `T`. Track an
  `in_async` flag for `await` validation.
- `await_expr`: operand must be `promise_type`; result is the inner `T`.
  `E_AWAIT_NOT_PROMISE` / `E_AWAIT_OUTSIDE_ASYNC`. Top-level `await` is allowed.
- `setTimeout`: builtin call, args `(() => void, int)`, returns void, sets
  `needs_async`.
- `Promise.resolve(v)`: returns `Promise<typeof v>`, sets `needs_async`.

### Emitter
- When `needs_async`, emit the runtime prelude: `LumenLoop` (timer list + ready
  queue, monotonic clock via `std.Io.Timestamp`/`std.Io.Clock.Duration.sleep`),
  `LumenPromise(T)` (resolved flag + value + `await_`), `__promiseResolved`, and
  `__setTimeout`. `uses_io` is forced on so `__io`/`__alloc` exist.
- `async` `function_decl`: emit return type `*LumenPromise(T)`; a `return v;`
  inside an async body emits `return __promiseResolved(T, v);`.
- `await_expr` -> `(<operand>).await_()`.
- `setTimeout(cb, ms)` -> `__setTimeout(<cb>, <ms>)`.
- `Promise.resolve(v)` -> `__promiseResolved(<T>, <v>)`.
- `main`: when `needs_async`, append `__lumen_loop.drain();` before returning.

## Verification

- Hand-written runtime prototype validated (resolved await, nested async await,
  timer-resolved await, timer ordering, captured-closure setTimeout).
- `examples/valid` (3) + `examples/invalid` (5) with a manifest mirroring 013.
- Wire `conformance_cmd_022` into `build.zig`; `zig build conformance` stays
  green including the new cases.
