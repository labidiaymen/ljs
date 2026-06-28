# Plan: async / await (minimal sound subset)

## Approach

Lower `Promise<T>` to a heap object and run the program on **libuv**, a real,
production event loop. Avoid a coroutine transform: an `async` function compiles
to an ordinary backend function returning `*LumenPromise(T)`, and `await p`
drives the libuv loop one event at a time until `p` is resolved, then reads
`p.value`. This is sound for the supported cases (immediately-resolved promises
and timer-resolved promises) and deterministic.

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
- When `needs_async`, emit `const uv = @cImport(@cInclude("uv.h"));` and the
  libuv-backed runtime prelude:
  - `LumenLoop`: `init()` captures `uv_default_loop()`; `driveUntil(ctx, done)`
    loops `uv_run(loop, UV_RUN_ONCE)` until `done(ctx)`; `drain()` runs
    `uv_run(loop, UV_RUN_DEFAULT)`.
  - `LumenPromise(T)` (resolved flag + value + `await_` that calls
    `LumenLoop.driveUntil`), `__promiseResolved`.
  - `__setTimeout(cb, ms)`: allocate a holder containing the callback and a
    `uv_timer_t`, `uv_timer_init` + `uv_timer_start` with the delay; the C
    callback invokes the closure, then `uv_timer_stop` + `uv_close` to tear the
    timer down. `uses_io` is forced on so `__alloc` exists.
- `async` `function_decl`: emit return type `*LumenPromise(T)`; a `return v;`
  inside an async body emits `return __promiseResolved(T, v);`.
- `await_expr` -> `(<operand>).await_()`.
- `setTimeout(cb, ms)` -> `__setTimeout(<cb>, <ms>)`.
- `Promise.resolve(v)` -> `__promiseResolved(<T>, <v>)`.
- `main`: when `needs_async`, call `LumenLoop.init();` after I/O setup and
  `LumenLoop.drain();` before returning.

### Linking (CLI, `src/lumen.zig`)
- libuv is a language-level dependency of async programs, not a user `// @link`.
  In `compileFile`, when the generated backend source contains the libuv import
  marker (`@cInclude("uv.h")`), inject libuv's flags into the `zig build-exe`
  argv via `collectAsyncRuntimeLibs`: `-lc` plus the tokens from
  `pkg-config --cflags --libs libuv`, falling back to `-I/opt/homebrew/opt/libuv/include`
  `-L/opt/homebrew/opt/libuv/lib` `-luv` when pkg-config is unavailable. The
  flags are added only for async programs.

## Verification

- libuv runtime prototype validated standalone (resolved await, nested async
  await, timer-resolved await, timer ordering, captured-closure setTimeout) and
  confirmed `otool -L` / `nm` show the binary linking and calling `uv_*`.
- `examples/valid` (3) + `examples/invalid` (5) with a manifest mirroring 013;
  all valid examples produce byte-identical stdout to the previous loop.
- Wire `conformance_cmd_022` into `build.zig`; `zig build conformance` stays
  green including the new cases.
