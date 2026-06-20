# Spec 088 — Array/String destructuring must observe a custom `@@iterator` (§8.5.2)

Status: Done — language 41,048 → 41,314 (+266), 92.3% → 92.9%, 0 regressions vs the post-087
passing snapshot, 0 panics, bench unchanged.
Owner: Aymen

## Problem

`destrOpen` (array/string destructuring, §8.5.2 IteratorBindingInitialization) took an unconditional
"fast path" that reads array indices / string code units directly, **bypassing the iterator
protocol**. This is only observably equivalent when the value's `@@iterator` is the pristine
intrinsic. A program that reassigns `Array.prototype[Symbol.iterator]` (or `String.prototype[…]`, or
gives the value an own `@@iterator`) MUST have its custom iterator driven — destructuring `[x, y, z]`
of `[1, 2, 3]` through a custom iterator that yields `42` for the 3rd element must bind `z = 42`.

266 Test262 cases (the `*-array-prototype` destructuring variants) failed on this — spread across
class method params, object methods, plain functions, arrows, generators, `for`/`for-of`, and
`let`/`const`/`var` declarations.

## Fix

Guard the fast path with a pristine check: take it only when the value's `@@iterator`, resolved
through the prototype chain, is the intrinsic native (`%Array.prototype.values%` = `array_values`,
or the String iterator = `string_iterator`). Otherwise fall through to the real §7.4 `GetIterator`
path (which the engine already supports as the `.iter` driver). A throwing accessor `@@iterator`
returns false too → the slow path re-reads and propagates the throw.

`src/interp_destr.zig`: add `iterMethodIsNative(value, want)`; condition the two fast-path arms on it.

## Acceptance

- **Given** `Array.prototype[Symbol.iterator] = function*(){ … yield 42 }` and `[x,y,z] = [1,2,3]`,
  **Then** `z === 42` (the custom iterator drove the binding).
- **Given** a plain array `[1,2,3]` with the pristine iterator, **Then** the fast path is still taken
  (no behavior/perf change) and bench shows no regression.
- **Regression:** 0 vs the post-087 language snapshot; bench no ljs-vs-self regression (the change is
  off the hot path for pristine arrays — one `@@iterator` identity probe).

## Out of scope

- Overriding `%ArrayIteratorPrototype%.next` (vs `@@iterator`) — a rarer variant; the `@@iterator`
  identity check covers the failing corpus.
