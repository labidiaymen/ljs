# Feature Specification: defer

**Feature Branch**: `tjs-native` (milestone 007) | **Created**: 2026-06-27 |
**Status**: Draft

**Input**: Borrow Zig's `defer` into the Lumen surface. Lumen already lowers to
Zig, so `defer` maps almost directly: a deferred statement/block runs at the end
of the enclosing scope, in last-in-first-out order.

## Requirements

- **FR-001**: `defer <statement>;` schedules a single statement to run at the end
  of the enclosing block.
- **FR-002**: `defer { ... }` schedules a block of statements to run at the end of
  the enclosing block.
- **FR-003**: Multiple `defer`s in the same scope run in last-in-first-out order
  (matching Zig).
- **FR-004**: The deferred body is type-checked in the enclosing scope.

V1 limits: a deferred body must not transfer control out of itself
(`return`/`break`/`continue`) — that is rejected by the Zig backend.

## Success Criteria

- **SC-001**: A function with two `defer`s prints its body first, then the
  deferred statements in LIFO order.
- **SC-002**: A `defer { ... }` block runs all its statements at scope exit.
- **SC-003**: `zig build conformance` passes with the feature 007 manifest.
