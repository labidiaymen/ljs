# Feature Specification: M2 — Core Built-in Library

**Feature Branch**: `003-builtin-library`

**Created**: 2026-06-15

**Status**: Draft

**Input**: User description: "M2: core built-in library (array literals + Array/String/Object/Math/Number methods) to raise Test262 conformance"

## User Scenarios & Testing *(mandatory)*

> Users: ljs engine developers / CI. M2's goal is **conformance-driven** — implement the
> built-ins that unblock the most currently-failing Test262 tests, raising the real pass rate
> above M1's 23.3% (`language/expressions`).

### User Story 1 - Arrays (Priority: P1)

Array literals (`[1, 2, 3]`), indexing, `.length`, and the core `Array.prototype` methods.

**Why this priority**: arrays are pervasive in real code and Test262; array literals don't even
parse yet, so this is the single biggest unblock.

**Independent Test**: `[1,2,3].length` → 3; `var a=[1,2]; a.push(3); a[2]` → 3; `[1,2,3].indexOf(2)` → 1.

**Acceptance Scenarios**:
1. **Given** `[10, 20, 30]`, **When** indexed/`.length` read, **Then** spec-correct values.
2. **Given** `push`/`pop`/`indexOf`/`includes`/`join`/`slice`/`map`/`forEach`, **When** called, **Then** spec-correct behavior.

### User Story 2 - String methods (Priority: P1)

`String.prototype` methods + indexing/`.length` on string values.

**Why this priority**: strings are everywhere; many expression tests read `.length`, `charAt`, `indexOf`, `slice`, `split`.

**Independent Test**: `"hello".length` → 5; `"abc".charAt(1)` → "b"; `"a,b,c".split(",").length` → 3.

**Acceptance Scenarios**:
1. **Given** a string, **When** a method (`charAt`/`charCodeAt`/`indexOf`/`includes`/`slice`/`substring`/`toUpperCase`/`toLowerCase`/`split`) is called, **Then** spec-correct result.
2. **Given** `"x".length`/`"x"[0]`, **When** read, **Then** correct (primitive boxing for property access).

### User Story 3 - Object statics & Object.prototype (Priority: P2)

`Object.keys`/`getOwnPropertyNames`/`create`/`getPrototypeOf`/`assign`/`defineProperty` and
`Object.prototype.hasOwnProperty`.

**Independent Test**: `Object.keys({a:1,b:2}).length` → 2; `({}).hasOwnProperty("x")` → false.

**Acceptance Scenarios**:
1. **Given** an object, **When** `Object.keys`/`hasOwnProperty` used, **Then** correct.
2. **Given** `Object.create(proto)`, **When** a proto property is read, **Then** it resolves.

### User Story 4 - Number, Math & numeric globals (Priority: P2)

`Math` (floor/ceil/abs/max/min/pow/sqrt/round/…), `Number` (isNaN/isFinite/isInteger/parseInt/parseFloat),
and the globals `NaN`/`Infinity`/`isNaN`/`isFinite`/`parseInt`/`parseFloat`.

**Independent Test**: `Math.max(1, 9, 4)` → 9; `Math.floor(3.7)` → 3; `isNaN(0/0)` → true.

**Acceptance Scenarios**:
1. **Given** a `Math`/`Number` call, **When** evaluated, **Then** spec-correct result.

### Edge Cases
- Out-of-range / negative array indices; `.length` mutation; sparse arrays (basic).
- Method calls on primitives (string/number) → transparent boxing for the call.
- `this`-sensitive built-ins (`Array.prototype.push.call`).

## Requirements *(mandatory)*

### Functional Requirements
- **FR-001**: Array literals parse and evaluate to array objects with a live `.length` and integer-indexed elements; out-of-range read → `undefined`.
- **FR-002**: Provide core `Array.prototype` methods: `push`, `pop`, `indexOf`, `includes`, `join`, `slice`, `forEach`, `map` (at minimum).
- **FR-003**: Property access on primitive strings/numbers boxes transparently; provide core `String.prototype` methods (`charAt`, `charCodeAt`, `indexOf`, `includes`, `slice`, `substring`, `toUpperCase`, `toLowerCase`, `split`) and string `.length`/indexing.
- **FR-004**: Provide `Object` statics (`keys`, `getOwnPropertyNames`, `create`, `getPrototypeOf`, `assign`, `defineProperty`) and `Object.prototype.hasOwnProperty`.
- **FR-005**: Provide `Math` and `Number` built-ins and the numeric globals listed above.
- **FR-006**: Each built-in carries inline ECMA-262 clause citations (Principle III).
- **FR-007**: ljs-vs-Node perf must not regress; ljs must remain ≤ Node on the benchmark set (the absolute pre-commit gate).

### Key Entities
- **Array object** — ordinary object of an array kind with a backing element list + `length`.
- **Bound/native method** — `Array.prototype`/`String.prototype`/`Object`/`Math` functions (native dispatch).
- **Primitive wrapper** — transparent boxing for `"str".method()` / `(3).method()`.

## Success Criteria *(mandatory)*
- **SC-001**: ≥40 unit tests across arrays/strings/objects/math pass (spec-correct).
- **SC-002**: Real conformance on `test/language/expressions` rises **meaningfully above 23.3%** (target ≥ 30%), recorded as the new baseline.
- **SC-003**: A `test/built-ins/Array` and `test/built-ins/String` slice passes **> 0** with the harness.
- **SC-004**: No M1 regression (curated sample still 27/6/2); **bench green, ljs ≤ Node**.
- **SC-005**: No leaks under the testing allocator.

## Assumptions
- Tree-walk tier retained (constitution IV); built-ins implemented as native functions (the `NativeId` dispatch from M1, extended).
- "Core" = the high-frequency methods that unblock the most tests; the full library tail continues in later milestones.
- Arrays are backed by a dynamic list; full exotic-array semantics (proxy-like length traps) are approximated for M2.

## Dependencies
- M1 engine (objects, functions, native dispatch, Error family), Test262 harness, bench gate.
- ECMA-262 §22 (String), §23 (Array), §20.1 (Object), §21 (Number/Math).
