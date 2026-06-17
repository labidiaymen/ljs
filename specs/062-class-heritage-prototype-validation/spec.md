# Feature Specification: Class heritage `prototype` validation

**Feature Branch**: `062-class-heritage-prototype-validation` (milestone **M74**)

**Created**: 2026-06-17

**Status**: Done — language 89.4% (39026 passing, +6 vs M73, 0 regressions)

**Input**: §15.7.14 ClassDefinitionEvaluation step (heritage): `protoParent = Get(superclass,
"prototype")`; if `protoParent` is **not an Object and not null**, throw a TypeError. ljs reads
the superclass's `.prototype` but, when it is a primitive (number / string / boolean / undefined /
symbol / bigint), silently ignores it instead of throwing — so `class C extends F {}` with
`F.prototype = 42` is accepted (should be a TypeError at definition time).

## User Scenarios & Testing *(mandatory)*

### User Story 1 — invalid heritage prototype is a TypeError (Priority: P1)

**Acceptance Scenarios**:

1. **Given** `function F(){} F.prototype = 42;`, **When** `class C extends F {}` is evaluated,
   **Then** TypeError.
2. **Given** `function F(){} F.prototype = "x";`, **When** `class C extends F {}`, **Then**
   TypeError.
3. **Given** `function F(){} F.prototype = undefined;`, **When** `class C extends F {}`, **Then**
   TypeError.

### Regression guards (must still hold)

1. `function F(){} F.prototype = null; class C extends F {}` — valid (a null protoParent is
   allowed; `C.prototype`'s `[[Prototype]]` is null, `F` is still the parent constructor).
2. `class B {} class C extends B {}` — valid (normal object prototype).
3. `class C extends null {}` — valid (`extends null`, unchanged path).

## Requirements

- **FR-001**: When the superclass evaluates to a callable object, read its `prototype`; if present
  and the value is neither an Object nor null, throw a TypeError. An object prototype links the
  derived prototype; a null prototype is accepted (no link). (§15.7.14)

## Success Criteria

- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.
- **SC-002**: `zig build bench` perf: ok (definition-time only; no hot path).
