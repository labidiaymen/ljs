# Tasks — spec 139 (template lexer nesting)
- [x] Rewrite lexTemplate → skipTemplateSubst (balanced) + skipNestedTemplate/skipNestedString helpers.
- [x] Skip nested templates (recursive), strings, line/block comments, and regex literals in `${…}`.
- [x] Micro-repros: nested `${ `\${x}` }`, regex-in-interp, escaped backtick/dollar-brace.
- [x] GATE: build/test/lint/bench + Test262 language (no regression); webpack parses 2 files deeper.
