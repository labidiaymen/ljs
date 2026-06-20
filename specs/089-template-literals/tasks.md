# Tasks — Spec 089 Template literals

- [x] T1. `ast.zig`: `template.raw`, cooked `?[]const u8`, new `tagged_template` node.
- [x] T2. `lexer.zig`: template octal / `\8` / `\9` escapes → InvalidEscape (SyntaxError).
- [x] T3. `parser.zig`/`parse_expr.zig`/`parse_validate.zig`: cooked+raw segments, TRV newline
      normalization, `${…}` as Expression, trailing-`.template` tagged call, `new tag\`…\``.
- [x] T4. `interpreter.zig`: per-realm `template_map`.
- [x] T5. `interp_template.zig` (new): `evalTaggedTemplate` + `getTemplateObject` (frozen object);
      extracted from `interp_expr.zig` to keep it under the 2000-line budget (was 2056 → 1952).
- [x] T6. `interp_property.zig`: strict add of non-index prop to non-extensible array → TypeError.
- [x] T7. Remove the 2 vacuous-pass TCO entries from `baseline/language.json` (documented).
- [x] T8. Gate: build/test/lint/bench green; full `language/` sweep 41,314 → 41,412 (+98), 93.1%,
      0 regressions vs baseline, 0 panics.
