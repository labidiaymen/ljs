# M26 tasks — iterable arguments + object-literal __proto__

## Part 1 — iterable `arguments` (§10.4.4 / §22.1.5)
- [x] T1 `makeArgumentsObject(args)` helper in `interpreter.zig`: ordinary object; index data props +
      non-enumerable `length` (unchanged) + mirror args into `.elements` (iterator backing); install
      `@@iterator` = a fresh `array_values` native (non-enumerable), keyed by the well-known
      `Symbol.iterator` (skipped only in a realm-less eval).
- [x] T2 Replace both inline arguments-creation blocks (ordinary call path + generator/async call
      path) with a call to the helper.
- [x] T3 Confirm every array fast path is `kind == .array`-guarded so the ordinary arguments object
      routes through the real `[Symbol.iterator]` protocol.

## Part 2 — object-literal `__proto__` (§B.3.1)
- [x] T4 `ast.Property.is_proto` flag.
- [x] T5 `parseObjectLiteral`: set `is_proto` for a `.init` colon property with a LITERAL
      (non-computed) name `__proto__`; record a deferred duplicate in `proto_dup` for the 2nd one.
- [x] T6 `parseStmt`: an undischarged `proto_dup` residue over the statement → SyntaxError.
- [x] T7 `validateAssignmentPattern` (object_literal): discharge `proto_dup` on refinement to an
      assignment pattern (duplicates allowed there per §13.15.1).
- [x] T8 `evalObjectLiteral` `.init`: when `is_proto`, set `obj.prototype` (object → it, null → null,
      primitive → ignored, no own prop); skip the ordinary property write.

## Tests + gates
- [x] T9 Tests in `src/engine.zig`: spread/for-of arguments (incl. generator); not Array.isArray;
      proto setter (object/null/primitive-ignored/string-name); computed `__proto__` is own prop;
      duplicate literal value → SyntaxError; duplicate in destructuring pattern → OK.
- [x] T10 Gates: build / test / lint (0/0) / conformance (language, harness prelude, ≥31224, 0
      regressions, baseline updated to 31239) / bench (perf: ok, ljs ≤ Node).
