# Implementation Plan: M2 — Core Built-in Library

**Branch**: `003-builtin-library` | **Date**: 2026-06-15 | **Spec**: [spec.md](./spec.md)

## Summary
Extend the tree-walk engine with the high-frequency built-ins (arrays + array literals, String/
Object/Math/Number methods) that unblock the most failing Test262 tests, raising real conformance
above M1's 23.3%. Still tree-walk, arena-per-realm; built-ins are native functions via the M1
`NativeId` dispatch (extended). Bench stays green (ljs ≤ Node) — the absolute pre-commit gate.

## Technical Context
Zig 0.16.0; pure std; tests `zig build test` + `zig build test262`; perf `zig build bench`
(ReleaseFast, min-gated). No GC (arena). No UB / no leaks.

## Constitution Check
I spec-source ✅ (§22/§23/§20/§21 cited) · II conformance gate ✅ (SC-002/003 raise the number) ·
III traceability ✅ (clause comments) · IV perf ✅ (tree-walk; bench ljs ≤ Node) · V incremental ✅
(one cycle per user story). No violations.

## Phase 0 — Decisions
- **D1 Arrays**: add an `array` Object kind backed by `std.ArrayListUnmanaged(Value)` + a `length`
  view; integer index get/set routes to the backing list, other keys to the property map.
  `Array.prototype` methods are native (`NativeId`), dispatched with `this` = the array.
- **D2 Native methods + `this`**: extend `NativeId` with array/string/object/math entries;
  `callNative` receives `this_val` (already threaded) + args. `arr.push` resolves via the array's
  prototype → native push.
- **D3 Primitive boxing**: `getProperty` on a string/number returns the matching
  `String.prototype`/`Number.prototype` method (or `.length` for strings) without a heap wrapper —
  a transparent read-only box, enough for method calls (FR-003).
- **D4 Object statics / Math / Number**: native functions on the `Object`/`Math`/`Number` globals;
  numeric globals (`NaN`/`Infinity`/`isNaN`/`isFinite`/`parseInt`/`parseFloat`).
- **D5 Scope discipline**: implement the high-frequency subset first (measured by what unblocks
  the most tests); document the deferred tail; re-measure conformance each cycle.

## Phase 1 — Artifacts
data-model/quickstart folded here (M2 is code-heavy). Contracts unchanged (CLI stable).

## Project Structure
`src/object.zig` (+ array kind, element list) · `src/builtins.zig` (+ Array/String/Object/Math/
Number natives + prototypes) · `src/interpreter.zig` (array-literal eval, array index get/set,
primitive boxing in getProperty, extended callNative) · `src/parser.zig`/`ast.zig` (array literal).

## Complexity Tracking
None — no violations.
