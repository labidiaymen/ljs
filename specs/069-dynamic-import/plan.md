# Implementation Plan: dynamic `import()` ImportCall (§13.3.10)

## Approach

Minimal, additive. One new AST node; one new parse path in `parsePrimary`; one new eval arm.

### Files / functions touched

- **`src/ast.zig`** — add a node:
  `import_call: struct { specifier: *const Node, options: ?*const Node }`
  (`options` is the optional 2nd argument — import options / attributes object; null for the
  1-arg form). §13.3.10.

- **`src/parser.zig`**
  - `parsePrimary` `.kw_import` arm: replace the blanket `return ParseError.UnexpectedToken`
    with: peek the token after `import`.
    - `(` → parse ImportCall: `(` AssignmentExpression [ `,` AssignmentExpression ] [ `,` ] `)`.
      - The argument(s) parse with `parseAssignment` (NOT `parseSpreadable`), so a `...spread`
        is rejected (§13.3.10 Forbidden Extension — no rest/spread). A leading `...` (current
        token) is an explicit SyntaxError before parsing the first arg.
      - Empty `import()` → SyntaxError (AssignmentExpression not optional).
      - A 3rd argument → SyntaxError (at most two).
      - Trailing comma after the 1st or 2nd arg is allowed.
    - anything else (incl. `.`) → `ParseError.UnexpectedToken` (covers `import.meta`,
      `import.UNKNOWN`, `import.source`, `import.defer`, a bare `import`, and static
      `import`/`export` declarations — all stay rejected, as before).
  - The resulting `import_call` node flows through `continuePostfix` (it returns from
    `parsePrimary`, whose caller `parsePostfix` calls `continuePostfix`), so `import('x')()`,
    `import('x').then`, `import('x')[k]` parse as a CallExpression chain — no extra work.
  - **Reject `import_call` as an UpdateExpression operand** (postfix AND prefix `++`/`--`),
    mirroring the existing `new_target` guards — `import('')++` / `++import('')` must be parse
    SyntaxErrors (ImportCall AssignmentTargetType is `invalid`).
  - **Assignment targets** already reject any non-(identifier/member/index/private/super) node,
    so `import('') = 1` and `import('') op= 1` and `import('') &&= 1` are rejected with NO change
    (the new node falls into the existing `else => UnexpectedToken` arms).
  - **`new import('x')`**: `parseNew` parses its callee via the member/new path; ImportCall is a
    CallExpression, not a MemberExpression, so `new import(...)` must be rejected. Verify
    `parseNew`'s callee path does not accept a primary that consumed a `( … )` call — if it
    would, add a guard. (See tasks.)
  - **Exhaustive `switch` obligation**: add an `.import_call` arm to `containsArguments`
    (parser.zig, no `else`). Add fidelity arms to `descendNode`, `nodeReferencesYield`,
    `nodeReferencesAwait` (they have `else`, but recursing into the specifier is correct).

- **`src/interpreter.zig`** — `evalExpr` (exhaustive switch, no `else`): add `.import_call`:
  1. Evaluate the specifier expression (abrupt → propagate).
  2. `newPromise()` to get a fresh pending Promise.
  3. ToString the specifier via `toStringCoerceV` (§13.3.10 step 6 ToString(specifier)).
     - If ToString is abrupt (a Symbol specifier, or a throwing `toString`/`valueOf`) →
       `rejectPromise(promise, reason)` (§13.3.10 step 7 IfAbruptRejectPromise).
  4. Otherwise (loader absent) → `rejectPromise(promise, <TypeError "module loading is not
     supported">)`. The 2nd argument (import options), if present, is evaluated for side effects
     after the specifier per §13.3.10's argument-evaluation order — but since we reject anyway,
     we evaluate it only if needed for spec-faithful ordering. (Decision: evaluate the options
     expression too, for GetValue side effects, before rejecting; abrupt → propagate.)
  5. Return `.{ .normal = .{ .object = promise } }`.

  Reuse existing Promise machinery: `newPromise`, `rejectPromise`, `throwError` (to build the
  TypeError Value).

## Design calls

- **No loader.** Per the task, the harness module loader is absent this cycle; `import(x)` always
  rejects with a TypeError after ToString. This is enough for the syntax tests + the
  `returns-promise` / `always-create-new-promise` style checks that only need a Promise.
- **Order of operations.** Evaluate specifier first, then (if present) the options argument, then
  ToString the specifier, then reject. Matches §13.3.10's left-to-right argument evaluation while
  keeping the ToString-reject behavior.
- **`import.meta` stays a SyntaxError** — not implemented; `import.<anything>` is rejected. This
  is the correct outcome for the `import.UNKNOWN` invalid test and does not regress anything.

## Constitution Check

- **Correctness-leads**: pure conformance work (language grammar + early errors + a real
  Promise). No speculative API surface.
- **Perf no-regression**: the change adds one rarely-taken parse branch and one eval arm; no hot
  path touched. `zig build bench` must show no regression before commit.
