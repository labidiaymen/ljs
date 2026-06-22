# Spec 119 — Node-compatible call stacks (`Error.prototype.stack`, captureStackTrace, CallSite)

**Status:** In progress. Goal: real V8/Node-format stack traces — so `err.stack` shows
`at <fn> (<file>:<line>:<col>)` frames, `Error.captureStackTrace` works, and
`Error.prepareStackTrace` hands user code real CallSite objects (the `depd`/Express blocker).

## Why
Today `Error.prototype.stack` returns `""` and the interpreter tracks NO call frames. Real Node code
(and `depd`, the last Express blocker after async I/O landed in spec 118) needs structured stack info.

## Design (tree-walker, perf-gated)
1. **Positions (foundation).** Tokens already carry a byte `pos`. Thread a `pos: u32` onto the `call`
   and `new_expr` AST nodes (the call-site offset). `parser.lineColOf(src, pos)` already maps
   offset→line:col.
2. **Frame stack.** `Interpreter.call_stack` — pushed/popped in `callFunction` for ordinary functions
   + constructors (and tagged native frames). Each frame: callee name, `func` object, `this`, flags
   (ctor/native/toplevel/eval), and a `cur_pos` updated to the call-site offset when the frame makes a
   call / constructs an Error. **Fixed-capacity, allocation-free push** (index by depth) to protect the
   hot path — re-bench mandatory.
3. **`.stack` string.** On Error construction, snapshot the top `Error.stackTraceLimit` frames; the
   `stack` getter formats them V8-style `<Name>: <msg>\n    at <fn> (<file>:<line>:<col>)`.
4. **captureStackTrace(target[, ctorOpt]).** Capture the live stack into `target.stack`, dropping
   frames at/above `ctorOpt`.
5. **prepareStackTrace + CallSite.** When `Error.prepareStackTrace` is a function, build CallSite
   objects (`getFileName`/`getLineNumber`/`getColumnNumber`/`getFunctionName`/`getMethodName`/
   `getTypeName`/`getThis`/`getFunction`/`isNative`/`isToplevel`/`isConstructor`/`isEval`/`toString`)
   and pass the array to the hook; its return value becomes `.stack`.

## In scope
User-thrown `new Error()` stacks, `captureStackTrace`, `prepareStackTrace`/CallSite, `stackTraceLimit`.

## Out of scope (for now)
Per-statement position precision for engine-thrown errors (TypeError mid-expression) — start with
call/new/Error-construction sites; refine later. Source maps. `--enable-source-maps`.

## Success criteria
- A 3-deep call throwing `new Error('x')` produces a multi-line `.stack` with correct `file:line:col`.
- `Error.captureStackTrace(o); o.stack` is a non-empty V8-format string skipping the right frames.
- `Error.prepareStackTrace = (e,cs)=>cs; new Error().stack` returns an array of working CallSites.
- 0 Test262 regressions (esp. `built-ins/Error`, the stack accessor tests) + `zig build bench` clean.
