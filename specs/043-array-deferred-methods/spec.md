# M43 — register the deferred Array.prototype methods + ArraySpeciesCreate + frozen/non-extensible array [[Set]]

## Goal
Register the M38-implemented-but-inert §23.1.3 methods (`filter`, `concat`, `splice`, `flat`,
`flatMap`, `shift`, `unshift`) on `Array.prototype` and `Array.from`/`Array.of` as statics — WITH the
supporting semantics that M38 deferred, so that registering them causes 0 regressions on the
`built-ins/Array` (and `language/`) Test262 partitions. The two missing pieces M38 named are
ArraySpeciesCreate-with-throw and a frozen/non-extensible array `[[Set]]` / CreateDataPropertyOrThrow.

## Part A — ArraySpeciesCreate (§10.4.2.3 / §23.1.3.x)
The result-building methods (`filter`, `concat`, `splice`, `slice`, `map`, `flat`, `flatMap`) must
create their output via ArraySpeciesCreate(originalArray, length):
1. `IsArray(originalArray)` is false → return a plain `ArrayCreate(length)` WITHOUT reading
   `constructor` (the `Array.prototype.filter.call(arrayLike)` case — `create-non-array.js`).
2. `C = Get(originalArray, "constructor")` — a poisoned getter propagates its abrupt completion
   (`create-ctor-poisoned.js`).
3. If `C` is an Object, `C = Get(C, @@species)`; a `null` species → undefined (`create-species-null`);
   a poisoned species getter propagates (`create-species-poisoned`).
4. `C` undefined → plain `ArrayCreate(length)` (`create-species-undef`).
5. `C` is NOT a constructor (incl. a non-object `constructor` value, or a non-ctor species) → TypeError
   (`create-ctor-non-object.js`, `create-species-non-ctor.js`).
6. else `Construct(C, « length »)` (`create-species.js`, `create-species-abrupt.js`).

`Symbol.species` is added to the well-known symbols (§20.4.2); `Array[Symbol.species]` is a getter
returning `this` (§23.1.2.5). M-subset: a plain Array is the common output; the species lookup +
TypeError path + a user-constructor result are all supported. The result is POPULATED via
CreateDataPropertyOrThrow (Part B), so a species that returns a non-extensible / frozen target throws,
and a species returning a non-Array object with a configurable non-writable index 0 has it redefined
(`target-array-with-non-writable-property.js`).

## Part B — frozen / non-extensible array `[[Set]]` + CreateDataPropertyOrThrow
An array tracks `extensible` (M6) but not per-element writability. Add `array_frozen: bool` (set by
`Object.freeze` on an array, alongside `extensible=false`): a frozen array's existing elements AND
`length` are non-writable; a sealed / preventExtensions array keeps writable elements but rejects a NEW
index. Then:
- The interpreter array `[[Set]]` path (`setProperty`): writing an existing index of a frozen array,
  growing/shrinking a frozen array's `length`, or adding a NEW index to a non-extensible array →
  TypeError in STRICT mode, silent no-op in sloppy (§10.4.2.4 ArraySetLength / §10.1.9.2).
- The mutating / populating methods (`push`/`unshift`/`shift`/`splice`/`fill`/`copyWithin`/`reverse`/
  `sort`, and the species-result population) use the THROWING form (Set/CreateDataPropertyOrThrow with
  Throw=true → always a TypeError on a frozen/non-extensible target, regardless of strict mode):
  `Object.freeze([1]).push(2)` / `.splice(0,1)` throw.

The dense hot path stays a single combined branch (`extensible && !array_frozen` → fast `arraySet`),
so a normal array set pays at most one extra boolean test.

## Part C — register
`filter`, `concat`, `splice`, `flat`, `flatMap`, `shift`, `unshift` on `Array.prototype`
(non-enumerable, via `defineMethod`); `Array.from`, `Array.of` as statics (`.array_static`). The
M38 method bodies are re-verified for hole / LengthOfArrayLike / `(el,i,arr)`+thisArg / flat depth /
`from` iterable+array-like+mapFn semantics; `filter`/`map`/`flat`/`flatMap`/`slice`/`concat`/`splice`
are rewired to allocate their result via ArraySpeciesCreate.

## Out of scope
- Proxy-based species targets (`create-proxy` / `create-revoked-proxy`); full per-element array
  property descriptors (an array index is always writable+enumerable+configurable unless the whole
  array is frozen). `%TypedArray%`. `create-proto-from-ctor-realm-*` (multi-realm).

## Gates
1. `zig build` · 2. `zig build test` · 3. `zig build lint` (0/0).
4. Conformance: `built-ins/Array` passed ↑ with 0 within-Array regressions (diff fail-set vs a
   snapshot of HEAD); `language/` "no regression" vs `baseline/language.json`. Neither baseline updated.
5. `zig build bench` — dense array path unchanged, "perf: ok", ljs ≤ Node.
