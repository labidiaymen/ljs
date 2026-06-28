# Implementation Plan: Array Higher-Order Methods

**Branch**: `tjs-native` (milestone 013) | **Date**: 2026-06-28 |
**Spec**: [spec.md](./spec.md)

## Summary

Add the common array instance methods to the Lumen compiler. Parsing already
produces a `method_call` node for `arr.m(...)`; this cycle teaches the checker to
recognize array receivers and validate the method/callback shapes, and teaches
the emitter to lower each method to an inline Zig expression block over the
underlying slice, invoking callbacks through the existing function-value
fat-pointer representation.

## Technical Context

**Language/Version**: Zig 0.16.0 (compiler + generated backend).

**Touched files**:
- `src/lumen_ast.zig` — extend `method_call` with checked element/result types.
- `src/lumen_check.zig` — array-receiver branch in the `method_call` checker.
- `src/lumen_compiler.zig` — array-method lowering in `emitExpr`.

**Reuse**: function-value signatures (`types.FuncSig`, `funcStructName`), the
`cb.call(cb.ctx, ...)` invocation form, `types.arrayElem`/`arrayOf`, and the
page-allocator memory model already used by templates/closures.

## Approach

1. **AST**: add `elem_type` and `result_type` (and for `reduce` an `acc_type`)
   fields to the `method_call` node so the checker can hand resolved types to the
   emitter.
2. **Checker**: when the receiver type is an array, branch on the method name:
   - build the expected callback `func_type` from the element type (and, for
     `reduce`, the accumulator type derived from `init`), then reuse
     `ensureAssignable` to validate the supplied callback;
   - validate argument counts and the `indexOf`/`includes`/`join` argument types;
   - compute and store the result type.
3. **Emitter**: for an array `method_call`, emit an inline `blk:` expression:
   - `map` → allocate `[]U` and fill via the callback;
   - `filter` → an `ArrayListUnmanaged(T)` collecting matches;
   - `forEach` → a loop calling the callback, yielding `{}` (void);
   - `reduce` → fold from `init`;
   - `find` → return `?T`;
   - `some`/`every` → boolean fold;
   - `indexOf`/`includes` → linear scan with value (string-aware) equality;
   - `join` → format each element into a buffer separated by `sep`.

## Constitution Check

- TypeScript source is the product: the methods follow standard JS/TS names and
  shapes; generated Zig stays an artifact. Pass.
- Static checking preserved: element types flow through; mismatches diagnose
  before native build. Pass.
- No new dynamic semantics: results are fresh slices, no receiver mutation. Pass.

## Milestone Strategy

Implement in small slices, building and running a scratch program after each:
1. `map`/`filter`/`forEach`.
2. `reduce`/`find`/`some`/`every`.
3. `indexOf`/`includes`/`join`.
Then add conformance examples (valid + invalid) and wire the manifest into
`build.zig`; keep `zig build conformance` green.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Inline blk lowering per call | Avoids monomorphized helper plumbing and keeps slices/closures composable | Shared generic helpers would still need per-signature instantiation and more emit machinery for the MVP |
