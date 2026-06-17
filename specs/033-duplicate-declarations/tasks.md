# M33 Tasks — Duplicate-declaration Early Errors

- [x] T1 Inspect failing Test262 cases (block-scope / switch / try-catch redeclaration) to fix the
      boundary: var-redeclaration legal, sloppy block function-vs-function legal (onlyStrict), nested
      `var` bubbles up to the enclosing block's VarDeclaredNames, catch enforces only the lexical conflict.
- [x] T2 Spec (`spec.md`) — rules §14.2.1 / §14.12.1 / §14.15.1 / §16.1.1 + boundary.
- [x] T3 Implement `checkLexicalScope` + helpers in `src/parser.zig`:
      collect LexicallyDeclaredNames (let/const/class/using; +function at block level),
      collect VarDeclaredNames (var + top-level function, bubbling up through nested non-function
      statements), check uniqueness + lexical∩var. Apply to Block, Script, FunctionBody, switch
      CaseBlock, catch. Emit `ParseError.UnexpectedToken`.
- [x] T4 Retire the staged-cut comment (c) in `src/interpreter.zig`.
- [x] T5 Engine tests (negatives + positives) in `src/engine.zig`.
- [x] T6 Gates: build / test / lint; full `language/` ≥ 36819, no regression; bench ok; baseline update.
- [x] T7 Commit + push (only if all gates green, 0 regressions).
