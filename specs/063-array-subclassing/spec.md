# Feature Specification: Array subclassing — exotic instance via super()

**Feature Branch**: `063-array-subclassing` (milestone **M75**)

**Created**: 2026-06-17

**Status**: Done — language 89.4% (39040 passing, +14 vs M74, 0 regressions)

**Input**: §23.1.1.1 + §15.7.14. `class S extends Array { constructor(n){ super(n); } }; new S(3)`
should produce an Array exotic instance (so `.length` tracks). ljs's construct model eagerly
creates the derived `this` as a `.plain` object, then `super(n)` invokes the `array_ctor` native —
which IGNORES `this`, builds a FRESH array, and returns it; that return is discarded in the
subclass path, so the instance never becomes an array (`new S(3).length === undefined`). The
collection constructors (Map/Set/WeakMap/WeakSet) already handle this correctly by initializing
their slot ON the provided instance when `native_new_target` is defined — Array must do the same.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — `extends Array` yields an Array exotic (Priority: P1)

**Acceptance Scenarios**:

1. **Given** `class S extends Array {}`, **When** `new S(3)`, **Then** `.length === 3`.
2. **Given** `class S extends Array {}` and `var s = new S()`, **When** `s[5] = "x"`, **Then**
   `s.length === 6` (exotic index→length tracking).
3. **Given** `class S extends Array {}`, **When** `var s = new S(1,2,3)`, **Then**
   `s.length === 3 && s[0] === 1` and `s instanceof S && s instanceof Array`.
4. **Given** `class S extends Array { constructor(){ super(2); } }`, **Then** `new S().length === 2`.

### Regression guards (must still hold)

1. `new Array(3).length === 3`; `new Array(1,2).length === 2`; `Array(3).length === 3` (plain call).
2. `[1,2,3]` literals, `Array.of`, `Array.from`, spread — unchanged.
3. `Array.isArray(new S())` is true for the subclass instance.

## Requirements

- **FR-001**: When `array_ctor` is invoked as a constructor (`native_new_target` defined) with an
  object `this`, initialize the Array exotic state ON that instance (flip it to an Array exotic,
  apply the §23.1.1.1 length/elements rule) and return it. A plain `Array(...)` call
  (`native_new_target` undefined) still returns a fresh array. (Mirrors the collection ctors.)

## Success Criteria

- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.
- **SC-002**: `zig build bench` perf: ok.
