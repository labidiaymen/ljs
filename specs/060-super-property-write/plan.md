# Implementation Plan: SuperProperty write (M72 / 060)

## Approach

### 1. AST (`src/ast.zig`)
Add a node for a plain super write: `super_assign: struct { name: []const u8 = "", key: ?*const Node = null, value: *const Node }`. Compound/logical/update keep the existing `super_member` target intact (their nodes already store `.target`).

### 2. Parser (`src/parser.zig`, `parseAssignment` ~1980–2035 + update-expr)
- Logical-assign target switch (~1989): add `.super_member` to the allowed set.
- Plain/compound switch (~2017): add `.super_member` to the allowed set.
- Plain-assignment break-out (~2030): `.super_member => |sm| return alloc(.{ .super_assign = .{ .name = sm.name, .key = sm.key, .value = rhs } })`.
- Update-expression target validation (prefix/postfix `++`/`--`): allow `.super_member`.

### 3. Interpreter (`src/interpreter.zig`)
- New `setSuperProperty(self, key, value) Completion` mirroring `getSuperProperty` (~1395):
  - `home = self.home_object orelse undefined-base`; `base = home.prototype`.
  - If `base` resolves `key` to an **accessor**: call its `set` with `this = self.this_val` and
    arg `value` (no setter → strict TypeError, sloppy no-op); return `value`.
  - Else: `return self.setProperty(self.this_val, key, value)` — §10.1.9.2 writes on the receiver.
- `evalExpr`:
  - `.super_assign`: eval the (optional computed) key once → eval value → `setSuperProperty`.
  - `.super_member` target in `evalCompoundAssign` (~1514), `evalLogicalAssign`, and the `.update`
    case (~1224): read via `getSuperProperty(key)`, compute, write via `setSuperProperty(key, …)`,
    evaluating the computed key exactly once and reusing it for both read and write.
- A small helper to resolve a `super_member`'s key string once (computed eval or static name),
  shared by read+write in the compound/update paths.

## Files touched
`src/ast.zig` (node), `src/parser.zig` (3 target switches + break-out + update), `src/interpreter.zig` (`setSuperProperty`, `super_assign`, compound/logical/update super cases).

## Risks
- LOW. Purely enables a currently-rejected construct; no passing test depends on the rejection.
- The receiver semantics (set on `this`, setter with `this`) must be right or class-field/setter
  tests could misbehave — covered by the conformance gate + the US1/US2 acceptance repros.
- Exhaustive `switch` over AST nodes in interpreter/parser must include the new `super_assign`
  (Zig compile error otherwise — a good forcing function).

## Constitution Check
- Correctness leads: implements §13.3.5/§6.2.5.6/§10.1.9.2. ✔
- Perf: no hot-path change; `zig build bench` gate. ✔
- Spec traceability: clauses cited inline. ✔
