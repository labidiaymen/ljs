# Tasks: dynamic `import()` ImportCall (§13.3.10)

- [x] T01 `src/ast.zig`: add `import_call: struct { specifier, options: ?* }` node (§13.3.10).
- [x] T02 `src/parser.zig` `parsePrimary` `.kw_import`: parse `import ( AssignmentExpression
      [, AssignmentExpression] [,] )`; early errors for `import()` (no arg), 3rd arg, leading or
      embedded spread. Non-`(` (incl. `.`) stays `UnexpectedToken`.
- [x] T03 `src/parser.zig`: reject `import_call` as a postfix/prefix UpdateExpression operand
      (`import('')++`, `++import('')`), mirroring the `new_target` guards.
- [x] T04 `src/parser.zig`: ensure `new import('x')` is rejected (ImportCall not a NewExpression
      target). Verify `parseNew`'s callee path; add a guard if needed.
- [x] T05 `src/parser.zig`: add `.import_call` arm to `containsArguments` (exhaustive switch);
      add fidelity arms to `descendNode`, `nodeReferencesYield`, `nodeReferencesAwait`.
- [x] T06 `src/interpreter.zig` `evalExpr`: add `.import_call` arm — eval specifier, eval options
      (if any) for side effects, ToString specifier, return a Promise rejected with TypeError
      ("module loading is not supported"); abrupt ToString rejects the promise.
- [x] T07 Gate: `zig build`, `zig build test`, `zig build lint` green; run the dynamic-import
      dir; record before/after pass counts. `zig build bench` no regression.
- [x] T08 Set Status in spec.md to Done with the measured delta.
