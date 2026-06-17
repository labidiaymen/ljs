# Feature Specification: Primitive-wrapper subclassing (Boolean/Number/String)

**Feature Branch**: `064-wrapper-subclassing` (milestone **M76**)
**Created**: 2026-06-17
**Status**: Done — language 89.4% (39046 passing, +6 vs M75, 0 regressions)

**Input**: §20.3.1.1/§21.1.1.1/§22.1.1.1 + §15.7.14. `class N extends Number { constructor(v){
super(v); } }; new N(42).valueOf()` should be 42. ljs boxes the primitive onto the instance only
for a DIRECT `new Number(x)` (constructNT) — the `super(x)` path discards the native's primitive
return, so the derived instance has no `[[NumberData]]`/`[[BooleanData]]`/`[[StringData]]` and its
prototype methods throw "called on incompatible receiver" (and `String` length is undefined).

## User Scenarios & Testing *(mandatory)*

### User Story 1 — wrapper subclass carries its primitive slot (Priority: P1)
1. **Given** `class N extends Number {}`, **When** `new N(42).valueOf()`, **Then** `42`.
2. **Given** `class B extends Boolean {}`, **When** `new B(true).valueOf()`, **Then** `true`.
3. **Given** `class S extends String {}` and `var s = new S("abc")`, **Then** `s.valueOf()==="abc"`,
   `s.length===3`, `s[0]==="a"`, and `s instanceof S && s instanceof String`.

### Regression guards
1. `new Number(5).valueOf()===5`; `new String("x").length===1`; `new Boolean(0).valueOf()===false`.
2. Plain calls `Number("3")===3`, `String(4)==="4"`, `Boolean(1)===true` (no boxing, primitive).
3. `typeof new Number(1) === "object"`; ToPrimitive of a wrapper still works.

## Requirements
- **FR-001**: When `number_ctor`/`string_ctor`/`boolean_ctor` is invoked as a constructor
  (`native_new_target` defined) with an object `this`, store the coerced primitive on that
  instance's slot and return the instance; a plain call returns the primitive. The redundant
  `constructNT` post-boxing is removed.

## Success Criteria
- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.  • **SC-002**: bench ok.
