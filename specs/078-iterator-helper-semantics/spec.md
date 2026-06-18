# M76 — Iterator-helper close/order semantics + helper/Symbol metadata

## Goal
Raise `built-ins/Iterator` and `built-ins/Symbol` conformance by fixing the highest-leverage
shared-root-cause clusters in the §27.1.4 iterator helpers and §20.4 Symbol, all within the
helper/Symbol-owning files (`builtin_iterator.zig`, `builtin_symbol.zig`, plus the cross-cutting
`object.zig` `nativeLength` table and the `runtime_types.zig` `HelperState`).

## Failing clusters addressed (Test262, histogrammed by reason)
1. **Helper/consumer `length` metadata absent** — `Iterator.prototype.{map,filter,take,drop,flatMap,
   reduce,forEach,some,every,find,toArray}`, `Iterator.from`, and the `Iterator` ctor had no own
   `length` property (the `.iterator_helper`/`.iterator_ctor`/`.iterator_from` ids were missing from
   `nativeLength`). 13 `length.js` files.
2. **Lazy-helper `return()` / `take` exhaustion swallowed a throwing underlying `return`** — these
   are §7.4.11 IteratorClose with a NORMAL completion, so a throwing `return` (or `return` getter)
   MUST propagate; the code used the swallowing `Interpreter.iteratorClose`. The
   `get-return-method-throws` / `iterator-return-method-throws` / `exhaustion-calls-return` files.
3. **Argument-order: callback/limit validated AFTER `next` was read** — the current spec forms the
   iterated record with `[[NextMethod]]` UNDEFINED and validates the callback (`IsCallable`) /
   numeric limit (`ToNumber`→NaN/negative) BEFORE GetIteratorDirect reads `next`; on failure it does
   IteratorClose (calls `return` ONLY, never `next`). We read `next` first. The
   `argument-effect-order` / `argument-validation-failure-closes-underlying` files (20).
4. **Re-entrant helper `next`/`return` while running** — `%IteratorHelperPrototype%.next` is a
   GeneratorResume; re-entering it from the mapper must throw a TypeError (GeneratorValidate "state
   is executing"). The `throws-typeerror-when-generator-is-running` files.
5. **`Symbol(description)` used the non-throwing ToString** — `it.toString` skips ToPrimitive on an
   object and does not throw on a Symbol. §20.4.1.1 step 2 is the full ToString: an object runs
   ToPrimitive(string) (observably calls `toString`/`valueOf`) and a Symbol description throws a
   TypeError. The `desc-to-string` / `desc-to-string-symbol` files.

## Out of scope / reported (live in forbidden files — interpreter, builtin_object, builtin_regexp,
## promise registration)
- `Object(symbol)` boxing (interpreter.zig `object_ctor`) does not set `[[SymbolData]]` nor
  `%Symbol.prototype%` as the wrapper proto ⇒ `Symbol.prototype.{description,valueOf,toString}` on a
  wrapper throw "not a Symbol". Blocks ~8 Symbol wrapper tests.
- Symbol-primitive property access does not auto-box to `%Symbol.prototype%` for symbol-keyed
  properties ⇒ `aSymbol[Symbol.toPrimitive]` is undefined. Blocks the `Symbol.toPrimitive` on-value
  tests.
- Array Iterator prototype chain is one layer short: `arrayIter → %Iterator.prototype% → Object.proto`
  instead of `arrayIter → %ArrayIteratorPrototype% → %Iterator.prototype%`. Blocks
  `Iterator/prototype/Symbol.iterator/*` (chain-navigation) tests.
- `Promise`/`RegExp` lack a `Symbol.species` getter (species/builtin-getter-name).
- `Iterator.prototype.constructor` / `[Symbol.toStringTag]` must be ACCESSOR properties with the
  special "weird setter" semantics (deferred from M56).
- 17 Symbol `cross-realm.js` (multi-realm — harness/out of scope).
- `Iterator.zip`/`Iterator.zipKeyed`/`Iterator.concat` (separate proposals, not implemented).

## Gates
build / test / lint / **Iterator ↑ / Symbol ↑** / language + built-ins no-regression / bench perf:ok.

## Result
Iterator 648→758/1028 (63.0%→73.7%; +110). Symbol 124→128/192 (64.6%→66.7%; +4).
Language: 0 regressions vs baseline. Built-ins: 0 regressions vs baseline. bench perf:ok.
