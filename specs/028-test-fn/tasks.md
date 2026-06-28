# Tasks: `test(...)` function form & `expect().toBe()`

- [x] T1 — Parser: recognize `test("name", () => { BODY });` in the `test` branch
      (lookahead on `(`), lowering to the same `test_decl` as the 008 block form.
- [x] T2 — Parser: `expect` statement branch (`peekIsOpenParen`): matcher form
      `expect(a).toBe(b)` / `.toEqual(b)` → `call __expectToBe` / `__expectToEqual`
      with `[actual, expected]`; boolean form `expect(cond)` → `call expect`;
      unknown matcher → `E_UNKNOWN_MATCHER`.
- [x] T3 — Checker: `__expectToBe` / `__expectToEqual` require `test_depth > 0`,
      two args, matching operand types (`E_TYPE_MISMATCH`); rewrite to
      `__expectStrEqual` for `.string` operands. Boolean `expect` unchanged.
- [x] T4 — Emitter: `__expectToBe` / `__expectToEqual` →
      `std.testing.expectEqual(expected, actual)`; `__expectStrEqual` →
      `std.testing.expectEqualStrings(expected, actual)`.
- [x] T5 — Ambient `lumen.d.ts`: `declare function test(name, fn)` and
      `declare function expect<T>(actual): { toBe; toEqual }`.
- [x] T6 — Examples: valid `test-fn.ts` (function form, passing `.toBe`/`.toEqual`
      + boolean `expect`); invalid `tobe-mismatch.ts` (matcher type mismatch).
- [x] T7 — Conformance manifest + `build.zig` wiring (`conformance_cmd_028`).
- [x] T8 — Verify: `zig build` clean; `lumen test` reports pass for a valid
      file and failure for a deliberately failing `.toBe`; legacy `test "…" {}`
      block (008) still green; full conformance stays at 204→ +new cases, 0 fail;
      new form type-checks under `tsc`.

## Deferred (follow-ups)

- [ ] Additional matchers (`.toBeTruthy`, `.toContain`, `.not.*`, `.toThrow`,
      deep equality for objects/arrays).
- [ ] Async test callbacks; `beforeEach`/`afterEach`; `describe` grouping.
