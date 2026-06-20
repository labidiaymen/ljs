# Tasks — Spec 097
- [x] T1. completion.zig: .empty variant, value-carrying brk/cont, updateEmpty/isAbrupt.
- [x] T2. interp_stmt: UpdateEmpty threading across block/if/loops/switch/try/with/labeled/break/continue.
- [x] T3. Handle .empty in engine/interpreter/interp_async/interp_expr/interp_module completion switches.
- [x] T4. max_depth 400→300 + extract loop/switch bodies (tco-* RangeError instead of panic).
- [x] T5. Follow-up: module_run async body loop continues on .empty (TLA regression fix).
- [x] T6. Gate: build/test/lint/bench green; language 42,187→~42,300, 95.1%, 0 regressions, 0 panics.
