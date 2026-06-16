# M17 — Iterator-correct array destructuring + step-bounded iterator loops

**Status:** DONE — full `language/` conformance 61.0% → 63.1% (+920), 0 regressions.

## Problem
Two defects in the array-pattern / iterator path:

1. **Correctness + hang (§8.5.2 / §13.15.5.3):** array destructuring (`bindPattern` /
   `assignPattern`) consumed the iterable by *draining it to completion* (`iterateToList`,
   then indexing). For a fixed pattern (`[x]`, `[a, b]`) the spec instead steps the iterator
   exactly once per element and, when the pattern is satisfied **without a rest element and the
   iterator is not done, calls IteratorClose (§7.4.11, `iterator.return()`)**. Draining an
   *infinite* iterator (e.g. `meth-ary-init-iter-close.js`, whose `next()` never reports `done`)
   spun forever in native code — the step watchdog never fired because the loop wasn't ticked.
   This hung the conformance runner at 99% CPU.

2. **Reliability:** even with stepping correct, a legitimately unbounded drain
   (`[...rest] = infiniteIterable`, `for (x of infiniteIterable)`, `[...infiniteIterable]`,
   `for await`) had no watchdog tick and could hang.

## Fix
- **Iterator-correct array destructuring:** `getIterator` once; step once per element (hole skips
  one step; default applies on `undefined`); only a rest element drains the remainder; after a
  non-rest pattern, `IteratorClose` if the iterator is not done; close on abrupt completion. No
  pre-drain for fixed patterns (so an infinite iterator with a fixed pattern is fine). Arrays keep
  the fast `.elements` path (unobservable for the built-in iterator).
- **Step-bounded loops:** every native loop that calls `iterator.next()` now `try self.tick()`s
  per iteration — `iterateToList` (spread), `for-of`, `for await`, the rest drain, `yield*`
  delegation. An unbounded iterator now fails with `StepLimitExceeded` (a normal test failure)
  instead of hanging the process.

## Result
- `meth-ary-init-iter-close.js` and the broader `class/dstr` / `assignment/dstr` iterator-close
  and step-count tests now pass; the full `language/` run completes (no hang).
- Conformance 61.0% → **63.1%**, 0 regressions vs baseline; bench green (off the hot path).
