# Feature Specification: Class constructor [[Call]] guard on every entry path

**Feature Branch**: `061-class-ctor-call-guard` (milestone **M73**)

**Created**: 2026-06-17

**Status**: Done — language 89.4% → 89.4% (39020 passing, +4 vs M72, 0 regressions). Required one
follow-on fix: `runParentCtor` now signals [[Construct]] even when the active new_target was lost
(arrow `()=>super()` invoked from an iterator-return handler after the ctor body left), so the new
guard does not misfire on `super()`.

**Input**: Conformance-discovered. §15.7.14 — a class constructor has a [[Call]] that
unconditionally throws a TypeError; it may only be invoked via [[Construct]] (`new` /
`super(...)`). ljs enforces this for a DIRECT call expression `C()` (checked in `evalCall` /
optional-call before dispatch) but NOT when the constructor is invoked through
`Function.prototype.call` / `.apply` / `.bind()()`, which reach `callFunction` directly and run
the body. `class C{}; C.call({})` returns without throwing (should be a TypeError).

## User Scenarios & Testing *(mandatory)*

### User Story 1 — class ctor via call/apply/bind throws (Priority: P1)

**Acceptance Scenarios**:

1. **Given** `class C {}`, **When** `C.call({})`, **Then** TypeError "Class constructor cannot be
   invoked without 'new'".
2. **Given** `class C {}`, **When** `C.apply(null, [])`, **Then** TypeError.
3. **Given** `class C {}` and `var f = C.bind({})`, **When** `f()`, **Then** TypeError.
4. **Given** `class B {} class C extends B {}`, **When** `C.call({})`, **Then** TypeError (not a
   "must call super" ReferenceError).

### Regression guards (must still hold)

1. `new C()` runs the constructor (a [[Construct]] sets [[NewTarget]] → no throw).
2. `super(...)` in a derived constructor runs the parent ctor (a construct path → no throw).
3. `new (C.bind({}))()` constructs normally.
4. An ordinary (non-class) function called via `.call`/`.apply`/`.bind` is unaffected.

## Requirements

- **FR-001**: A class constructor's [[Call]] throws a TypeError regardless of entry path (direct,
  call/apply/bind, or any future native dispatch), but its [[Construct]] does not. The signal is
  the one-shot `pending_new_target` hand-off `callFunction` already consumes: undefined ⇒ [[Call]],
  set ⇒ [[Construct]].

## Success Criteria

- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.
- **SC-002**: `zig build bench` perf: ok (a single check off the existing consume — no hot-path
  regression; ordinary calls pay one already-loaded-field test).
