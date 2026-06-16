# M21 — `with` statement (§14.11)

**Status:** DONE — `language/` 63.1% → 63.2% (+59, 0 regressions). Implemented solo (subagent API
was overloaded).

## What
- Parse `with ( Expression ) Statement` (`kw_with`). §14.11.1 Early Error: a `with` in strict-mode
  code is a SyntaxError (rejected via the parser's `strict` flag).
- Runtime (§14.11.7 / §9.1.1.2 Object Environment Record): `ToObject` the operand (null/undefined →
  TypeError; primitive ToObject boxing not modeled — M-subset uses an empty object), run the body in
  an Environment whose `with_object` is the binding object.
- Identifier resolution through a `with` scope (§9.1.1.2.1): consult the binding object's
  `HasProperty` (proto chain) first, else fall through to the lexical chain. Reads → `[[Get]]`,
  writes → `[[Set]]`.

## Design — zero hot-path cost
The interpreter tracks `with_depth` (count of active `with` scopes). When 0 (every program without a
`with`), identifier GET/SET take the unchanged fast `env.lookup` path — **no added cost on the
benchmarked hot path**. Only when `with_depth > 0` does resolution use `resolveIdRef`, which walks
the chain consulting object Environment Records. The `with` binding object is stored on `Environment`
as an opaque pointer (`?*anyopaque`) to avoid the Object↔Environment import cycle.

## Notes / deferred
- `@@unscopables` filtering not implemented (minor deviation).
- `with`-scope resolution wired into identifier GET, the `assign` SET, and the `assignToTarget`
  PutValue helper (covers reads, simple writes, destructuring writes). `typeof x` / `x++` through a
  `with` use the generic paths; the common cases are covered.
- Keyword-as-property-name: `with` added to `isKeywordName` so `obj.with` / `{with: 1}` / accessor
  `with` still parse (IdentifierName allows reserved words).
