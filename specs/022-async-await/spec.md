# Spec: async / await (minimal sound subset)

## Goal

Add the smallest sound, runnable subset of TypeScript's asynchronous model to
Lumen, backed by a real single-threaded event loop:

1. **`async function f(...): Promise<T> { ... }`** — declares an asynchronous
   function. Its declared return type must be `Promise<T>`; a `return v;` inside
   the body produces a resolved `Promise<T>` whose value is `v`.
2. **`await expr`** — where `expr` has type `Promise<T>`, yields a `T`. `await`
   is only valid inside an `async function` or at the top level of the program.
3. **`Promise<T>`** — a first-class type usable in annotations, variables, and
   `async` return positions.
4. **`Promise.resolve(v)`** — produces an already-resolved `Promise<T>` for the
   type of `v`.
5. **`setTimeout(callback, ms)`** — schedules `callback: () => void` to run after
   at least `ms` milliseconds on the event loop. Returns `void`.

A `Promise<T>` is resolved either immediately (`Promise.resolve`, an `async`
function whose body returns synchronously) or later by a timer. `await` drives
the event loop until the awaited promise is resolved, then reads its value. The
program drains any remaining timers before exiting, so fire-and-forget
`setTimeout` callbacks still run.

## Surface Rules

- `async` may only prefix a top-level `function` declaration. The return
  annotation must be `Promise<T>` for some supported `T`.
- A non-`void` `async function` must return on every path, exactly like an
  ordinary function (the returned value is the resolved value).
- `await` requires a `Promise<T>` operand and produces `T`. Using `await` on a
  non-promise is a type error; using it outside any function and outside an
  `async` function body is rejected.
- `setTimeout`'s first argument must be a `() => void` callback; its second must
  be an integer millisecond delay.
- `Promise.resolve(v)` infers `Promise<T>` from the static type of `v`.

## Diagnostics

- `E_AWAIT_NOT_PROMISE` — `await` applied to a non-`Promise` operand.
- `E_AWAIT_OUTSIDE_ASYNC` — `await` used in a non-`async` function body.
- `E_ASYNC_RETURN` — an `async function`'s return annotation is not `Promise<T>`.
- `E_TYPE_MISMATCH` — `setTimeout` callback/delay types, or a `Promise.resolve`
  misuse.
- `E_ARG_COUNT` — wrong argument count to `setTimeout` / `Promise.resolve`.

## Out of Scope (V1)

- `Promise.all`, `Promise.race`, `.then(...)` chaining, rejection / `catch` on
  promises, and `async` arrow functions.
- True suspension/resumption mid-function (no coroutine transform): an `async`
  body runs to completion on first call, and `await` is a loop-driven wait. This
  is sound for the supported cases (resolved promises and timers) and keeps
  ordering deterministic.
- Cancellation and `clearTimeout`.
