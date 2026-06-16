# M20 — Array.prototype keys/entries + iterator self-iterability

**Status:** DONE — `language/` 63.1% (+6, 0 regressions). Small on `language/` (Array-method
tests live mostly in `built-ins/Array`, not vendored), but it's correct stdlib + fixes a latent bug.

## What
- `Array.prototype.keys` (§23.1.3.18) and `Array.prototype.entries` (§23.1.3.7) — Array Iterators
  yielding indices and `[index, value]` pairs respectively. `.values` already existed (M8).
  Implemented by adding an `IterKind` (`value`/`key`/`entry`) to the native iterator state and
  branching in `iteratorNext`.
- **Latent-bug fix:** native Array/String iterator objects had a `next` method but no
  `[Symbol.iterator]` returning `this` (§27.1.2.1 %IteratorPrototype%). So `for (x of arr.values())`
  / `[...arr.keys()]` (iterating the iterator object directly) failed with "not iterable". Added the
  self-`[Symbol.iterator]` (reusing the return-`this` native), fixing `.values()` too.

## Note
The bulk of Array.prototype is still incomplete (every/some/filter/reduce/find/flat/sort/splice/…)
and those tests are in `built-ins/Array` which is not in the vendored corpus — a future stdlib
milestone once the corpus is expanded to `built-ins/`.
