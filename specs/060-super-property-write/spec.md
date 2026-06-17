# Feature Specification: SuperProperty as an assignment / update target

**Feature Branch**: `060-super-property-write` (milestone **M72**)

**Created**: 2026-06-17

**Status**: Done — language 89.3% → 89.4% (39016 passing, +12 vs M71, 0 regressions). Modest
because many `super`-write tests are gated behind other unfinished class semantics; the parse
gap + write semantics are now correct (all US1/US2 repros pass).

**Input**: Conformance-discovered. `super.x` / `super[k]` parse and evaluate as a READ
(`getSuperProperty`), but using one as the target of an assignment (`super.x = v`), compound
assignment (`super.x += v`), logical assignment (`super.x ??= v`), or update (`super.x++`,
`--super[k]`) is a `SyntaxError: UnexpectedToken` — the parser excludes `.super_member` from
assignment/update target validation. ~45–65 failing tests under `expressions/super` +
`statements/class` / `expressions/class`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — assign to a super property (Priority: P1)

§13.3.5 MakeSuperPropertyReference + §6.2.5.6 PutValue: `super.x = v` performs an ordinary
`Set` whose *base* is the home object's `[[Prototype]]` but whose *receiver* is the current
`this` — so a setter on the prototype runs with `this` = the instance, and a plain write lands
on the instance.

**Acceptance Scenarios**:

1. **Given** `class B { set x(v){ this._x = v; } } class C extends B { m(){ super.x = 5; return this._x; } }`,
   **When** `new C().m()`, **Then** returns `5` (the prototype setter ran with `this` = instance).
2. **Given** `class B {} class C extends B { m(){ super.y = 7; return this.y; } }`, **When**
   `new C().m()`, **Then** returns `7` (plain write lands on the receiver/instance).
3. **Given** computed `super[k] = v` with `k = "z"`, **When** invoked, **Then** writes `z`.

### User Story 2 — compound / logical / update on a super property (Priority: P2)

**Acceptance Scenarios**:

1. **Given** `class B { get x(){return 10;} set x(v){this._x=v;} } class C extends B { m(){ super.x += 5; return this._x; } }`,
   **When** invoked, **Then** `this._x === 15` (read via the getter = 10, write via the setter).
2. **Given** `super.x++` where the getter returns 3, **Then** the update expression's value is 3
   (postfix) and the setter receives 4.

### Out of scope

- Strict-mode rejection of a write to a non-writable DATA property found on the super chain
  (a rare edge; the common cases are setters / plain receiver writes). May be added if a test
  requires it.

## Requirements

- **FR-001**: Parser accepts `.super_member` as the target of `=`, compound `op=`, logical
  `&&=`/`||=`/`??=`, and prefix/postfix `++`/`--` (§13.15.1 / §13.4 — a SuperProperty is a valid
  SimpleAssignmentTarget). The existing `super` parse restriction (only inside a method/home
  context) is unchanged.
- **FR-002**: `Set` semantics with `receiver = this` (§10.1.9.2): a setter on the super chain is
  invoked with `this` = the current receiver; otherwise the value is written on the receiver.
- **FR-003**: Compound/logical/update read via `getSuperProperty` and write via the new
  `setSuperProperty`, evaluating the (computed) key exactly once.

## Success Criteria

- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.
- **SC-002**: `expressions/super` parse_error cluster clears; gains in `statements/class` /
  `expressions/class` super-write tests.
- **SC-003**: `zig build bench` perf: ok (no hot-path change expected).
