---
description: "Task list for M8 — iterator protocol + Symbol (§6.1.5 / §6.1.7 / §7.4 / §20.4 + for-of/spread/destructuring wiring, conformance-driven)"
---

# Tasks: M8 — Iterator Protocol + Symbol

**Metric:** conformance is reported **WITH the Test262 harness prelude** (`--harness-dir
vendor/test262/harness`, the standard Test262 way), same as M4–M7. The continuity gate is
`language/expressions`; the committed baseline `baseline/language-expressions.json` (M7 close: passed
**6,718**, **39.6%**) is the floor — M8 must hold it and push it UP (the dominant remaining
`assignment/dstr` / `object/dstr` / `for-of` / spread failures need the real §7.4 protocol, which is gated
on the missing `symbol` primitive + `Symbol.iterator`).

**Cadence**: one cycle = one coherent slice = one commit (build + test + lint + **bench (ljs ≤ Node)**
green). Re-measure `language/expressions` (continuity gate) each cycle.

**Mandatory regression hunt (every cycle):** the new `symbol` Value variant touches every exhaustive
`switch (value)` (typeof / equality / ToPrimitive / printing) and the symbol-keyed store touches the
Object property model — engine-wide risk; the for-of/spread/destructuring re-wiring touches three hot
consumers. Capture the per-test result set (by `mode+path`) before and after (`git stash` the worktree,
rebuild ReleaseFast, `--update-baseline` to a JSON pass-id set, `comm`); true-regressions must be 0 or far
outweighed by recoveries. Do NOT commit a net regression on the continuity gate.

## Cycle 1 — `symbol` primitive + minimal `Symbol` + §7.4 protocol + for-of/spread/destructuring wiring (US1–US6) 🎯 (DONE — continuity gate (`language/expressions`, harness): passed 6,718 → **6,825** (+107), **0 true regressions / 107 recoveries** by `mode+path`; conformance 39.6% → **40.2%**. The recoveries are the iterator-observing tests across spread / `for`/`of` / `typeof`-symbol / symbol-keyed-property and the iterator-shaped slice of the destructuring subtrees that M7 close flagged. Bench green: `perf: ok (no ljs-vs-self regression)`, ljs 0.2–0.5× Node — the symbol store is a separate map (string get/set hot path untouched) and the for-of/spread/destructuring native-iterator fast-path keeps Arrays/Strings off the per-element `.next()` dispatch. Committed baseline bumped 6,718 → 6,825.)
- [x] M8-T010 **Value — `symbol` primitive (`src/value.zig`)** — new sixth primitive variant on the `Value`
  union (§6.1.5): an opaque identity (unique id) + optional description string. `typeof` → `"symbol"`;
  `===`/`!==`/`SameValue` compare **identity** (`Symbol() !== Symbol()`, `s === s`). Every exhaustive value
  `switch` handles it: ToString / ToNumber / **implicit** ToPrimitive (template, `+`) throw a TypeError;
  `String(sym)` / `sym.toString()` are allowed (→ `"Symbol(d)"`). `.description` reads back the optional
  description (`undefined` when omitted).
- [x] M8-T020 **`Symbol` constructor + well-known symbols (`src/builtins.zig`)** — a callable `Symbol`
  in the global (§20.4.1): `Symbol([description])` returns a fresh symbol, `new Symbol()` throws a TypeError
  (callable-not-constructor). The four well-known symbols this milestone consumes — `Symbol.iterator`,
  `Symbol.asyncIterator`, `Symbol.toStringTag`, `Symbol.hasInstance` (§20.4.2) — as stable realm-level data
  properties of `Symbol` (pairwise distinct, identity-stable across reads).
- [x] M8-T030 **Symbol-keyed property store (`src/object.zig`)** — a **separate** symbol-keyed map on the
  Object, keyed by symbol identity (§6.1.7 property keys). Non-enumerated: invisible to `for-in` /
  `Object.keys` / `Object.values`/`entries` / spread / JSON / string-key iteration. The string-keyed
  get/set **hot path is untouched** — the symbol store is consulted only when the property key is a symbol.
  ToPropertyKey keeps a symbol key as a symbol (`obj[sym]` ≠ `obj[String(sym)]`); a computed-key literal
  `{[sym]: v}` stores under the symbol.
- [x] M8-T040 **§7.4 iteration protocol (`src/abstract_ops.zig`, §7.4.2–.4.8)** — `getIterator` (calls
  `obj[Symbol.iterator]()`, requires an Object result else TypeError), `iteratorNext` / `iteratorStep`
  (call `.next()`, read `done`/`value`, non-object result throws), `iteratorClose` (calls `.return()` if
  present on early finish and **preserves the original completion** per §7.4.8 — a body throw wins over a
  `.return()` error), `iterateToList` (drive to exhaustion into a slice). Native iterator fast-path for
  unmodified Array/String avoids per-element `.next()` dispatch.
- [x] M8-T050 **Wiring for-of / spread / array destructuring onto §7.4 (`src/interpreter.zig`)** — for-of
  (§14.7.5), array spread (`[...x]`, `f(...x)`, §13.2.4), and array destructuring (`bindPattern` +
  `assignPattern`, §13.15.5) now `GetIterator` → loop on `IteratorStep` → **IteratorClose on
  break/return/throw** (a body `break`/`return`/`throw`, a destructuring target that throws, an
  early-finished pattern). A user object with `[Symbol.iterator]` is iterable everywhere; Arrays/Strings
  keep the native fast-path. Native `Array.prototype[Symbol.iterator]` (=== `.values`, §23.1.5) +
  `String.prototype[Symbol.iterator]` (§22.1.3 / §6.1.4) return native iterator objects.
- [x] M8-T060 **Tests (`src/engine.zig`, all green)** — `typeof`/identity/description; `Symbol()` vs
  `new Symbol()` (TypeError); implicit-coercion TypeError (template, `+`) vs `String(sym)` / `.toString()`;
  symbol-keyed store + non-enumeration (`Object.keys` empty, `for-in` visits nothing); the four well-known
  symbols distinct + stable; the §7.4 protocol (hand-rolled user iterable drives for-of to `0,1,2`;
  `.return()` called once on early `break`; non-object `.next()` throws); native iterators
  (`[...[1,2,3]]`, `[...("ab")]`, `for (const c of "hi")`).
- [x] **Conformance + regression hunt (harness, ReleaseFast, `git stash` HEAD vs working-tree `comm`):**
  continuity gate `language/expressions` `passed 6,718 → 6,825` (+107), 39.6% → **40.2%** — **0 true
  regressions / 107 recoveries** by `mode+path`. The before set (stash → 6,718) was verified to equal the
  committed baseline; restore → 6,825; `comm` showed 0 regressions / 107 recoveries. Bench green. Committed
  baseline bumped 6,718 → 6,825.
- [x] **Landed:** the `symbol` primitive Value variant (typeof `"symbol"`, identity equality, description,
  Symbol→string throws in template / `+` but allowed via `String()` / `.toString()`); the `Symbol()`
  constructor (rejects `new`) with the well-known symbols `iterator` / `asyncIterator` / `toStringTag` /
  `hasInstance`; a separate symbol-keyed property store on Object (non-enumerated; string get/set hot path
  untouched); the §7.4 iteration protocol (`getIterator` / `iteratorStep` / `iteratorClose` /
  `iterateToList`) wired into for-of (with IteratorClose on break/return/throw), spread, and array
  destructuring (`bindPattern` + `assignPattern`); native `Array.prototype[Symbol.iterator]` / `.values`
  + `String.prototype[Symbol.iterator]` iterators. **Deferred (future cycles):** the Symbol registry
  (`Symbol.for` / `Symbol.keyFor`), the full `Symbol` built-in surface (remaining well-known symbols +
  `Symbol.prototype` methods + the `toStringTag` / `hasInstance` behavioral hooks), `Map`/`Set`,
  **generators/`yield`** (the big remaining lever — the language-level iterator *producer*), and async
  iteration (`Symbol.asyncIterator` / `for-await-of`).

## Future cycles (planned)
- **Cycle 2 — Symbol registry + full Symbol surface:** `Symbol.for` / `Symbol.keyFor` (the cross-realm
  registry), the remaining well-known symbols (`toPrimitive` / `match` / `replace` / `search` / `split` /
  `species` / `isConcatSpreadable` / `unscopables`), `Symbol.prototype` (`toString` / `valueOf` /
  `description` getter / `[Symbol.toPrimitive]`), and the behavioral hooks for the symbols already exposed
  (`Object.prototype.toString` `[Symbol.toStringTag]` dispatch, `instanceof` `[Symbol.hasInstance]`).
- **Cycle 3+ — generators / `yield` (the next MILESTONE):** generator functions (`function*`) and `yield`
  / `yield*` — the language-level iterator *producer*. This is the dominant remaining lever: it makes
  user-defined iterators ergonomic and unblocks the generator-shaped slice of `for-of` / spread /
  `assignment/dstr` / `object/dstr` that the protocol alone cannot reach. Likely a milestone of its own
  (suspend/resume of the tree-walk evaluator, generator state machine), then async iteration
  (`Symbol.asyncIterator` / `for-await-of`) and `Map`/`Set` on top of the now-real protocol.

## Dependencies / order
Cycle 1 lands the whole minimal-Symbol + §7.4 + re-wiring slice in one commit (they are inseparable — the
protocol can't be recognized without `Symbol.iterator`, and re-wiring for-of/spread/destructuring is what
turns the protocol into conformance). The §7.4 path is the shared substrate every future iterator consumer
sits on: Cycle 2 widens the Symbol surface, the generators milestone adds the iterator *producer* underneath
it, and `Map`/`Set` + async iteration layer on last. Each cycle bench-gated (the symbol store is a separate
map; the for-of/spread native fast-path keeps the hot loop off `.next()`) and runs the before/after
`mode+path` regression hunt.
