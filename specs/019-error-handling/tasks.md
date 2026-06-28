# Tasks: Error Handling (019)

- [x] T1: Write spec.md / plan.md / tasks.md for cycle 019.
- [x] T2: Emit the try body as one shared-scope block so locals declared in the
  try are visible across try statements.
- [x] T3: Lower `throw` with a throw target to set the message slot and break out
  of the enclosing try block (skip the rest of the try body).
- [x] T4: Lower `finally` to a leading `defer` over the whole try/catch region so
  it runs on every exit, including a rethrow from the catch body.
- [x] T5: Suppress an unused catch capture (`_ = e;`), pick `var`/`const` for the
  slot, and stop emitting statements after an unconditional `throw` so the
  generated Zig has no unused-symbol or unreachable-code errors.
- [x] T6: Add examples/valid + examples/invalid and conformance/manifest.json.
- [x] T7: Wire the 019 manifest into build.zig and verify `zig build conformance`
  is green including the new cases.
