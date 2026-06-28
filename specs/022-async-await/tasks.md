# Tasks: async / await (minimal sound subset)

## Slice 1: AST + parser (P1)
- [x] T1.1 AST: `FunctionDecl.is_async`; `Expr.await_expr`; `Program.needs_async`.
- [x] T1.2 Parser: `async function ...` sets `is_async`.
- [x] T1.3 Parser: `await <expr>` in `parseUnary`.
- [x] T1.4 Parser: `Promise` added to std namespaces (`Promise.resolve`).

## Slice 2: types (P2)
- [x] T2.1 `Type.promise_type`; wire `zigName`, `mangle`, `same`, `toAnnotation`.

## Slice 3: checker (P3)
- [x] T3.1 `typeFromAnnotation` resolves `Promise<T>`.
- [x] T3.2 `declareFunction`: async return must be `Promise<T>` (`E_ASYNC_RETURN`).
- [x] T3.3 `checkFunctionBody`: async-body return checks against inner `T`;
  track `in_async` for `await`.
- [x] T3.4 `await_expr`: promise operand -> inner `T`; `E_AWAIT_NOT_PROMISE`,
  `E_AWAIT_OUTSIDE_ASYNC`.
- [x] T3.5 `setTimeout` builtin call; `Promise.resolve` static call.

## Slice 4: emitter (P4)
- [x] T4.1 Runtime prelude emitted when `needs_async`.
- [x] T4.2 Async function returns `*LumenPromise(T)`; `return v` wraps to resolved.
- [x] T4.3 `await_expr`, `setTimeout`, `Promise.resolve` emission.
- [x] T4.4 `main` drains the loop when `needs_async`.

## Slice 5: conformance (P5)
- [x] T5.1 Valid examples: resolved await, nested async await, setTimeout.
- [x] T5.2 Invalid examples: await non-promise, await outside async, async
  non-Promise return, setTimeout arg types, arg count.
- [x] T5.3 Manifest + wire into `build.zig`; `zig build conformance` green.
