# M35 Tasks — Hashbang + object-method super + new.target

## Feature 1 — HashbangComment (§12.5)
- [x] T1.1 `Lexer.init`: consume a leading `#!...` (offset 0) to end of line (`\n`/`\r`/U+2028/U+2029).
- [x] T1.2 A `#!` not at offset 0 stays a PrivateIdentifier error (no change needed; verified).

## Feature 2 — SuperProperty in object-literal methods (§13.3.5 / §13.2.5)
- [x] T2.1 Parser: set `in_method` in `parseMethodBody` (covers all class + object method bodies).
- [x] T2.2 Parser: set `in_method` before `parseParams` in each object-method site (method, accessor,
      generator/async method) so a `super`-bearing default parameter parses.
- [x] T2.3 Runtime: `evalObjectLiteral` installs `home_object` on object-literal methods (gated on
      the AST `function` node `is_method`) and on accessors (always methods).
- [x] T2.4 Runtime: move `this`/[[HomeObject]]/[[NewTarget]] install in `callFunction` BEFORE the
      param-init loop (§10.2.11) so `super.k` in a default parameter resolves correctly.

## Feature 3 — NewTarget meta-property (§13.3.12)
- [x] T3.1 AST: add `new_target` Node variant.
- [x] T3.2 Parser: add `in_function` flag (set in `parseFunction`, `parseMethodBody`,
      `parseStaticBlock`, field-init parse; arrows inherit it).
- [x] T3.3 Parser: parse `new` `.` `target` in `parseNew`; reject non-`target` / escaped; §13.3.12.1
      SyntaxError outside a function (`!in_function`).
- [x] T3.4 Parser: §13.4.1.1 — reject `new_target` as an update / assignment target.
- [x] T3.5 Interpreter: add `new_target` + `pending_new_target` fields; eval the `new_target` node;
      `construct` sets the pending target; `callFunction` consumes it (undefined for ordinary calls).
- [x] T3.6 Interpreter: propagate `new.target` down `super(...)` chains (`runParentCtor`, default
      derived ctor).

## Tests + Gates
- [x] T4.1 `src/engine.zig`: hashbang, object-method super, new.target tests (incl. SyntaxError cases).
- [x] T4.2 `zig build` + `zig build test` (exit 0) + `zig build lint` (0/0).
- [x] T4.3 Conformance: `language/` passed 37292 → 37407 (85.7%), 0 regressions; baseline updated.
- [x] T4.4 `zig build bench` — absolute pre-commit gate (perf: ok, ljs ≤ Node).
