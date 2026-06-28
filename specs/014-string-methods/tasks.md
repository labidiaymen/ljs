# Tasks: String Instance Methods

## Slice 1: dispatch + predicates/queries (P1)
- [x] T1.1 AST: add `string_method` flag to `method_call`.
- [x] T1.2 Checker: `string` receiver branch; validate `charAt`, `charCodeAt`,
  `indexOf`, `includes`, `startsWith`, `endsWith` and compute result types.
- [x] T1.3 Emit inline `blk:` lowering for those methods.

## Slice 2: transforms (P2)
- [x] T2.1 Checker: `slice`/`substring` (optional end), `toUpperCase`,
  `toLowerCase`, `trim`, `repeat`, `padStart`, `replace`.
- [x] T2.2 Emit lowering for the transform methods.

## Slice 3: split (P3)
- [x] T3.1 Checker: `split(sep)` -> `string[]`.
- [x] T3.2 Emit `split` lowering returning a `[]const []const u8`.

## Slice 4: conformance (P4)
- [x] T4.1 Valid examples covering each method with expected stdout.
- [x] T4.2 Invalid examples: arg type mismatch, arg count, unknown method.
- [x] T4.3 Manifest + wire into `build.zig`; `zig build conformance` green.
