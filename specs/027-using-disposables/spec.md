# Feature Specification: `using` Declarations & Disposables

**Feature Branch**: `tjs-native` (milestone 027) | **Created**: 2026-06-28 |
**Status**: Implemented

**Input**: Add TypeScript 5.2 `using` declarations for scope-exit cleanup. The
existing `defer <stmt>;` statement is not valid TypeScript (it is a parse error
under `tsc`). `using` is valid TS with the same LIFO scope-exit semantics, so
routing cleanup through `using` keeps `.ts` sources `tsc`-clean. This is also the
foundation for later resource-cleanup and arena-scope work.

## Surface

The built-in `defer(fn)` helper is the `tsc`-clean spelling of the old `defer`
statement. Its disposal runs `fn` at scope exit:

```ts
function run(): void {
  using _ = defer(() => console.log("done"));
  console.log("work");
}
// prints: work, done
```

Multiple `using` declarations in one scope dispose in reverse (LIFO) order, and
`using` interleaves correctly with the legacy `defer` statement:

```ts
function run(): void {
  using _a = defer(() => console.log("a"));
  using _b = defer(() => console.log("b"));
  console.log("work");
}
// prints: work, b, a
```

A class instance exposing `dispose(): void` is disposed at scope exit:

```ts
class Resource {
  name: string;
  constructor(name: string) { this.name = name; }
  dispose(): void { console.log(`closing ${this.name}`); }
}

function run(): void {
  using r = new Resource("db");
  console.log(`using ${r.name}`);
}
// prints: using db, closing db
```

## Semantics

- `using NAME = EXPR;` binds `NAME` and arranges for `EXPR`'s disposal when the
  enclosing block or function scope exits.
- Disposal is LIFO across all scope-exit cleanups in a scope — `using`
  declarations and legacy `defer` statements share one ordered set.
- Two disposal shapes are recognized:
  - **`defer(() => BODY)`** — the built-in helper. `BODY` runs at scope exit.
    This is the must-have, `tsc`-clean path.
  - **class instance with `dispose(): void`** — `NAME.dispose()` runs at scope
    exit. (Compiler-level Lumen convenience; see "tsc compatibility" below.)
- A `using` value that is neither shape is rejected with `E_NOT_DISPOSABLE`.

## tsc compatibility

- `using _ = defer(() => ...)` type-checks cleanly under `tsc` (5.2+) with the
  repo-root `lumen.d.ts`, which declares
  `declare function defer(fn: () => void): Disposable;` and an `interface
  Disposable { dispose(): void }` (merged with the ESNext lib's `Disposable`).
  The generated `tsconfig.json` already targets ESNext.
- `tsc`'s native `using` requires the disposed value to implement
  `[Symbol.dispose]()`, not a plain `dispose()` method. Lumen's `dispose()`-based
  class disposal therefore works at the Lumen-compiler level but is **not**
  `tsc`-clean unless the class also implements `[Symbol.dispose]`. Full
  `[Symbol.dispose]` support (computed method names) is deferred to a follow-up;
  the `defer(...)` helper is the `tsc`-clean cleanup path for V1.

## Legacy `defer`

The `defer <stmt>;` statement remains a fully supported alias with unchanged
behavior. Existing examples and the 007-defer conformance case continue to pass.

## Lowering

`using` reuses the existing scope-exit machinery: each declaration lowers to a
native `defer` block placed inline at the declaration site, so the LIFO ordering
and interleaving with legacy `defer` statements come for free. See `plan.md`.
