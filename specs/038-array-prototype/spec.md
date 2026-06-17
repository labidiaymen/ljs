# M38 — Array.prototype standard-library methods + sparse/lazy array length

## Goal
Close the largest `is not a function` cluster under `built-ins/Array/prototype` by implementing the
missing §23.1.3 methods, and fix the conformance-run OOM caused by eager hole materialization on a
length increase / sparse index assignment.

## Part A — sparse/lazy array length (§23.1 Array exotic)
Today an Array's backing is a dense `elements: ArrayListUnmanaged(Value)` and `length` is derived as
`elements.items.len`. Setting `arr.length = HUGE` or `arr[1e9] = x` eagerly fills millions of holes
→ ~5 GB RSS → OS-kill of the `built-ins/Array` run.

Fix — track `length` SEPARATELY from the dense store:
- `Object.array_length: usize` is the array's `[[Length]]` (meaningful iff `kind == .array`).
- Dense prefix stays in `elements.items` (indices `0 .. elements.items.len`).
- A `sparse: ?*AutoHashMapUnmanaged(usize, Value)` overflow map holds far-out index writes.
- Invariant: `array_length >= elements.items.len`.
- Index get: dense slot if `i < elements.items.len`; else sparse map; else `undefined` (hole).
- Index set: if `i` is contiguous/near (`i < elements.items.len + GAP_CAP`, GAP_CAP small), grow
  dense (fill `undefined`) and bump `array_length`; else store in sparse + bump `array_length`. No
  eager fill of the whole `[old_len, i)` range.
- `length` set: smaller → truncate dense + drop sparse entries `>= new_len`; larger → just record
  `array_length` (no fill).
- Small/contiguous arrays (literals, `push`) stay on the dense fast path (hot index get/set
  unchanged: a single bounds check + slice index).

This alone lets the full `built-ins/Array` subtree COMPLETE (no OOM).

## Part B — Array.prototype methods (§23.1.3) — GREEN SLICE
Spec algorithms (§23.1.3.x): LengthOfArrayLike, callback `(element, index, array)` + thisArg, hole
handling (forEach/map/some/every/reduce skip holes; find*/fill visit them), arg coercion via
ToIntegerOrInfinity (a Symbol arg throws TypeError), HasProperty/Get walk the prototype chain (an
inherited index is still visited). `sort` default comparator = ToString ascending; optional comparator
fn; holes + undefined sort to the end.

LANDED (registered, 0-regression):
- Iteration/search: `every`, `some`, `find`, `findIndex`, `findLast`, `findLastIndex`, `reduce`,
  `reduceRight`, `lastIndexOf`, `at`, `map` (+ `indexOf`/`includes`/`slice`/`join` correctness).
- In-place mutation: `reverse`, `fill`, `copyWithin`, `sort`.

DEFERRED (implemented in `builtin_array.zig` but NOT registered → inert): `concat`, `splice`,
`filter`, `flat`, `flatMap`, `shift`, `unshift`, `Array.from`, `Array.of`. Registering only their
common path REGRESSES the Test262 tests that today pass because the method is a missing stub that
throws "not a function" — specifically the ArraySpeciesCreate (`create-species-*`, `create-ctor-non-
object`), non-extensible/non-configurable result-target, and frozen/non-writable-length cases. Those
require ArraySpeciesCreate-with-throw + a frozen/non-extensible [[Set]] / CreateDataPropertyOrThrow,
which is out of the current M-subset. Follow-up milestone.

## Collateral correctness fixes (unblock the built-ins conformance run)
Two pre-existing latent panics aborted the full `built-ins` run (a Zig `panic` kills the process, so
the run never completes):
- `abstract_ops.numberToString`: `@intFromFloat` into `i64` for any integral number `< 1e21` panics
  for values in `[2^63, 1e21)`. Fixed: integer fast path only `< 9.2e18`; larger integral values use
  float formatting (also makes `String(1e20)` correct).
- `builtin_string.idxArg`: `@intFromFloat(n)` for a huge `slice`/`substring` index panics. Fixed: cap
  to `maxInt(usize)` before the conversion (the caller clamps to the string length anyway).
Both are strict improvements (panic → correct value); language baseline unaffected.

## Out of scope
- `%TypedArray%` methods; `Array.prototype[Symbol.unscopables]`; full ArraySpeciesCreate with a
  user `Symbol.species`. Generic application of these methods to non-Array array-likes via
  `Array.prototype.x.call(arrayLike)` is best-effort (the M-subset operates on the Array exotic).

## Gates
1. `zig build` · 2. `zig build test` · 3. `zig build lint` (0/0).
4. Conformance: `language/` no regression vs `baseline/language.json`; `built-ins/` ≥ 7744 AND no
   regression vs `baseline/builtins.json`, then update that baseline.
5. `zig build bench` — dense array path unchanged, "perf: ok", ljs ≤ Node.
