# Spec 089 — Template literals: TV/TRV + tagged-template caching (§12.9.6, §13.2.8)

Status: Done — tagged-template 2→44/48, template-literal 74→114/114; language 41,314 → 41,412
(+98 net), 92.9% → 93.1%; 0 regressions vs the committed baseline (see note on the 2 TCO entries).
Owner: Aymen

## Problem

ljs had essentially no tagged-template support and several template-literal gaps:
- A `.template` token after a callee was never consumed as a call (`tag\`…\``), the `template` AST
  node carried no raw (TRV) strings, and there was no §13.2.8.3 template-object cache.
- TV/TRV escape computation: tagged raw strings didn't exist; `${…}` substitution values were
  ToString-coerced before reaching the tag (must be passed raw); template octal / `\8` / `\9`
  escapes were decoded leniently instead of being SyntaxErrors; each `${…}` was re-parsed as a
  Program (statement context) so `${function(){}()}` / `${{a:1}}` mis-parsed.

## Fix (subsystem modules)

- `ast.zig`: `template` node gains `raw: []const []const u8`; cooked becomes `?[]const u8` (null =
  illegal escape → `undefined` for the tagged cooked array); new `tagged_template` node.
- `lexer.zig`: template-mode escape decoding returns InvalidEscape for octal/`\8`/`\9`.
- `parser.zig` / `parse_expr.zig` / `parse_validate.zig`: produce cooked+raw segments with
  `<CR>`/`<CR><LF>`→`<LF>` TRV normalization; parse `${…}` as an Expression with inherited context;
  consume a trailing `.template` as a `tagged_template`; `new tag\`…\``; AST-walker arms.
- `interpreter.zig`: per-realm `template_map` (§13.2.8.3 [[TemplateMap]], keyed by `quasi` node id).
- `interp_template.zig` (NEW): `evalTaggedTemplate` + `getTemplateObject` (frozen template object:
  frozen `raw` array, non-enumerable/non-writable/non-configurable `.raw`, frozen indices/length).
  Extracted from `interp_expr.zig` to keep it under the 2000-line budget (it had grown to 2056).
- `interp_property.zig`: strict-mode add of a new non-index property to a non-extensible array now
  throws TypeError (needed by the frozen template object; was wrongly excluded).

## Note — 2 baseline entries removed (TCO)

`expressions/tagged-template/tco-call.js#strict` and `tco-member.js#strict` (`features:
[tail-call-optimization]`, 100 000-deep tail recursion via tagged templates) previously passed
**vacuously** — tagged templates weren't real calls, so the recursion never happened. Now that
tagged templates correctly make real calls, they require Proper Tail Calls (§15.10 PrepareForTailCall),
which ljs does not implement, so they overflow. They were removed from `baseline/language.json` (the
only two floor members that regress) with this documentation; net change is +100/−2. PTC remains a
known, separate, unimplemented feature.

## Out of scope
- Proper Tail Calls (`tail-call-optimization`).
- `cache-realm` (needs `$262.createRealm`).
