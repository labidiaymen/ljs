# Tasks: Array Higher-Order Methods

## Slice 1: map / filter / forEach (P1)
- [x] T1.1 AST: add `elem_type`/`acc_type`/`result_type` to `method_call`.
- [x] T1.2 Checker: array-receiver branch; validate `map`/`filter`/`forEach`
  callbacks and compute result types.
- [x] T1.3 Emit inline `blk:` lowering for `map`/`filter`/`forEach`.
- [x] T1.4 Scratch program compiles + runs.

## Slice 2: reduce / find / some / every (P2)
- [x] T2.1 Checker: `reduce` accumulator type from `init`; boolean-callback and
  `find` result types.
- [x] T2.2 Emit `reduce`/`find`/`some`/`every` lowering.
- [x] T2.3 Scratch program compiles + runs.

## Slice 3: indexOf / includes / join (P3)
- [x] T3.1 Checker: value-argument methods; `join` optional separator.
- [x] T3.2 Emit `indexOf`/`includes`/`join` lowering (string-aware equality).
- [x] T3.3 Scratch program compiles + runs.

## Slice 4: conformance (P4)
- [x] T4.1 Valid examples (one per method) with expected stdout.
- [x] T4.2 Invalid examples: callback type mismatch, value-arg mismatch, arg
  count.
- [x] T4.3 Manifest + wire into `build.zig`; `zig build conformance` green.
