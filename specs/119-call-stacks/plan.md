# Plan — Spec 119 call stacks

## Files
- `src/ast.zig`: `pos` on `call`/`new_expr` nodes.
- `src/parser.zig` + `src/parse_expr.zig`: `Parser.source` + `tokenOffset()`; record call-site offset
  (callee start, matching V8) on `call`, `new` offset on `new_expr`; thread `base_off` through
  `continuePostfix`.
- `src/runtime_types.zig`: `FunctionData.src`/`src_name`; `StackFrame` + `FrameKind`.
- `src/object.zig`: `Object.error_stack` (captured frames).
- `src/interpreter.zig`: `call_stack`/`pending_call_pos`/`script_source`/`script_name` fields;
  `pushFrame`/`popFrame`/`captureStack`/`captureStackTraceInto` helpers; capture in `throwError`.
- `src/interp_expr.zig`: push frames in `callFunction` (native + ordinary); set `pending_call_pos` in
  `evalCall`/`evalNew`. The 3 `createFunction` sites stamp `src`/`src_name`.
- `src/interp_native.zig`: `error_ctor`/aggregate/suppressed capture; `.stack` getter → `error_stack.build`;
  `callsite_method` dispatch.
- `src/host_setup.zig`: `Error.captureStackTrace` handler (skip ctorOpt + install own `stack` accessor).
- `src/engine.zig`: thread `script_source`/`script_name`; push a synthetic top-level frame.
- `src/error_stack.zig` (NEW): V8 string formatter + CallSite objects + `callsiteMethod` dispatch.

## Constitution Check
- **Correctness leads:** ljs `.stack` is byte-identical to Node on the user frames (3-deep throw,
  captureStackTrace+ctorOpt skip, prepareStackTrace/CallSite); only Node's internal module-loader
  frames differ (unreplicable). 0 Test262 language regressions.
- **Perf gate:** the hot-path cost is one `pushFrame`/`popFrame` per call (a fixed-size append + a
  pop) + a capture (alloc) only at error construction. `zig build bench` shows no ljs-vs-self
  regression. (Bonus: ljs captures+formats stacks ~3.6× faster than Node — 146k vs 41k stacks/sec.)

## Out of scope
Per-statement positions for engine-thrown errors mid-expression (start with call/new/Error sites);
async "await" stack stitching; source maps.
