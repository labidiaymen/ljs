# Feature Specification: Error / NativeError subclassing

**Feature Branch**: `065-error-subclassing` (milestone **M77**)
**Created**: 2026-06-17
**Status**: Done — language 89.4% (39048, +2 vs M76, 0 regressions). Error subclass dir 33%->67%; remaining NativeError failures are pre-existing message-descriptor deviations (separate milestone).

**Input**: §20.5.1.1 + §15.7.14. `class E extends Error { constructor(m){ super(m); } }; new E("x")`
should be an Error-tagged instance with `.message === "x"`. ljs's `error_ctor` native builds a
FRESH error object (proto = Error.prototype) and the subclass `super(m)` path discards it, so the
derived instance has no `[[ErrorData]]`/message (`new E("x").message === undefined`). Mirror the
Array (M75) / wrapper (M76) / collection fix: initialize the error ON the constructed instance.
(Scope: the redirect only; pre-existing Error-message-descriptor deviations — enumerable, set even
when undefined — are intentionally left for a separate milestone to keep this low-risk.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Error subclass is a proper error (Priority: P1)
1. **Given** `class E extends Error {}`, **When** `new E("boom")`, **Then** `.message === "boom"`,
   `e instanceof E`, `e instanceof Error`, and `Object.prototype.toString.call(e) === "[object Error]"`.
2. **Given** `class E extends TypeError {}`, **When** `new E("t")`, **Then** `.message === "t"` and
   `e instanceof TypeError`.
3. **Given** `class E extends Error { constructor(){ super("z"); this.x = 1; } }`, **Then**
   `new E().message === "z" && new E().x === 1`.

### Regression guards
1. `new Error("x").message === "x"`; `new TypeError("y") instanceof TypeError`.
2. `Object.prototype.toString.call(new Error()) === "[object Error]"`.

## Requirements
- **FR-001**: When `error_ctor` (and the NativeError variants it backs) is invoked as a constructor
  (`native_new_target` defined) with an object `this`, initialize the error state ([[ErrorData]],
  message, name) ON that instance and return it; a plain call still creates a fresh error.

## Success Criteria
- **SC-001**: `language/` conformance up, **0 regressions** vs baseline.  • **SC-002**: bench ok.
