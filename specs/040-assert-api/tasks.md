# Tasks: assert API

## Phase 1

- [x] T1 Added `"assert"` to the parser's `isStdNamespace` list. New
  `assertCallType` in `lumen_check_stdlib.zig`, wired into `staticCallType`.
- [x] T2 `assert.ok(cond)` -- `bool -> void`, lowers to `__assertOk`
  (`@panic` on failure).
- [x] T3 `assert.equal(a, b)` -- `(T, T) -> void`; strings route to
  `__assertStrEqual` (same trick as `expect(...).toBe(...)`'s
  `__expectStrEqual`), everything else to a generic `anytype` `__assertEqual`
  using `std.debug.panic` to show both mismatched values.
- [x] T4 Verified: the success path for both functions (no panic, program
  continues); all three failure paths (`assert.ok(false)`,
  `assert.equal(2+2, 5)`, `assert.equal("foo","bar")`) halt execution
  before the next statement and produce a clear, correctly-formatted
  error message with the actual mismatched values shown.
- [x] T5 `zig build test` passes. `zig build conformance` run clean.
- [x] T6 Update `website/stdlib.html`: new `assert` quick-jump list +
  function blocks; update Planned table; add to the docs-nav sidebar.
- [x] T7 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `deepEqual`/`deepStrictEqual` (needs
recursive structural comparison), `throws`/`doesNotThrow` (needs a way to
catch a panic, which is a bigger feature since panics are uncatchable by
design here), a custom message argument.
