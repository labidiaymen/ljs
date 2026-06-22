# Tasks — Spec 119 call stacks

- [x] AST: `pos` on `call`/`new_expr`; parser `tokenOffset` + record callee-start / `new` offsets
- [x] FunctionData `src`/`src_name`; stamp at the 3 `createFunction` sites; thread `script_source`/name
- [x] `StackFrame`/`FrameKind`; interpreter `call_stack` + `pending_call_pos` + push/pop helpers
- [x] Push frames in `callFunction` (native + ordinary); set `pending_call_pos` in evalCall/evalNew
- [x] Capture at Error construction (error ctors + `throwError`); `Object.error_stack`
- [x] V8 string formatter (`error_stack.zig`); `.stack` getter wired
- [x] Omit the Error-ctor frame; callee-start columns; synthetic top-level `Object.<anonymous>` frame
- [x] `Error.captureStackTrace(target[, ctorOpt])` — skip ctorOpt + install own `stack` accessor
- [x] `Error.prepareStackTrace` + CallSite objects (`callsite_method`): getFileName/LineNumber/…
- [x] Verify byte-identical to Node: 3-deep throw, captureStackTrace, prepareStackTrace/CallSite
- [x] Gate: test + lint + bench + Test262 language differential (0 regressions); built-ins/Error stable
- [ ] (future) engine-thrown error mid-expression positions; async stack stitching; source maps
