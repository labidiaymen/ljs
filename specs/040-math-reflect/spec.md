# 040 — Complete Math (§21.3) + implement Reflect (§28.1)

## Goal
Two bounded, host-free built-ins. Raise `built-ins/Math` conformance by adding the
missing §21.3.2 methods and the §21.3.1 value properties, and implement the `Reflect`
namespace object (§28.1) from 0 — a thin wrapper over the Object/internal reflection
operations already used by `Object.*`, but returning booleans instead of throwing on
ordinary failure.

Scope: 100% ECMAScript, NO host APIs. The engine is deterministic and the Zig sandbox
blocks `std.crypto`/`Date.now`/host RNG, so `Math.random` is a fixed-seed xorshift.

## Baselines (before)
- `built-ins/Math`: 181/654 (27.7%)
- `built-ins/Reflect`: 0/306 (0%)
- `baseline/language.json`: MUST NOT regress.

## Part A — Math (§21.3)

### §21.3.1 value properties — non-writable, non-enumerable, non-configurable
`E`, `LN10`, `LN2`, `LOG10E`, `LOG2E`, `PI`, `SQRT1_2`, `SQRT2`.
Plus `Symbol.toStringTag = "Math"` (non-writable/non-enumerable/configurable).

### §21.3.2 methods — each ToNumber-coerces its args, returns a Number
Already present: `pow floor ceil abs round trunc sign sqrt max min`.
Added: `sin cos tan asin acos atan atan2 sinh cosh tanh asinh acosh atanh exp expm1
log log2 log10 log1p cbrt hypot fround clz32 imul random`.

Semantics fixed in this milestone:
- `round` (§21.3.2.28): half-up toward +Infinity — `floor(x + 0.5)`, but with the
  exact-spec edge cases: NaN/±0/±Inf pass through; a value in `(-0.5, 0)` and `-0`
  return `-0` (so `Math.round(-0.5)` is `-0`, not `0`); very large integers pass
  through unchanged (no `x+0.5` rounding error).
- `sign` (§21.3.2.30): NaN→NaN, +0→+0, -0→-0, else ±1 — uses `std.math.sign` which
  already preserves the zero sign and NaN.
- `max`/`min` (§21.3.2.24/.25): ToNumber each arg; any NaN → NaN; `-0`/`+0` ordering
  (`max(+0,-0)=+0`, `min(+0,-0)=-0`). Identity is `-Inf`/`+Inf`.
- `fround` (§21.3.2.29): round-trip through `f32`.
- `clz32` (§21.3.2.11): ToUint32 then count leading zeros (32 for 0).
- `imul` (§21.3.2.19): ToInt32 both, multiply mod 2^32, reinterpret as Int32.
- `hypot` (§21.3.2.18): variadic; any ±Inf arg → +Inf (even with a NaN present); else
  NaN if any NaN; else `sqrt(Σ xᵢ²)`.
- `log2`/`log10`/`log1p`/`expm1`/`cbrt`/`atan2`/the hyperbolics: `std.math` equivalents.
- `random` (§21.3.2.27): a fixed-seed xorshift64* mapped to `[0,1)`. NOT `Date.now`/host
  RNG (blocked in this sandbox). Test262 only checks the result is a Number in `[0,1)`.

All methods are non-writable / non-enumerable / configurable function values on the Math
namespace object (proto = %Object.prototype%); `Math` itself is not callable.

## Part B — Reflect (§28.1)

A `Reflect` global ordinary object (proto = %Object.prototype%, NOT a constructor, NOT
callable), `Symbol.toStringTag = "Reflect"` (§28.1.14). Methods (all require `target`
be an Object → TypeError otherwise):

- `apply(target, thisArg, argsList)` (§28.1.1) — IsCallable(target); CreateListFromArrayLike(argsList); Call.
- `construct(target, argsList[, newTarget])` (§28.1.2) — IsConstructor(target); optional
  newTarget (defaults to target) drives the constructed [[NewTarget]] / proto (M35).
- `get(target, key[, receiver])` (§28.1.6) / `set(target, key, value[, receiver])` (§28.1.13) — [[Get]]/[[Set]].
- `has(target, key)` (§28.1.9) → boolean (the `in` semantics, chain walk).
- `deleteProperty(target, key)` (§28.1.4) → boolean.
- `ownKeys(target)` (§28.1.11) → array: own string keys (Array indices, then string
  props), then own symbol keys.
- `getPrototypeOf` (§28.1.8) / `setPrototypeOf(target, proto)` (§28.1.14) → boolean.
- `isExtensible` (§28.1.10) / `preventExtensions` (§28.1.12) → boolean.
- `defineProperty(target, key, attrs)` (§28.1.3) → boolean (does NOT throw on a failed
  define — returns false, unlike Object.defineProperty).
- `getOwnPropertyDescriptor(target, key)` (§28.1.7) → descriptor object or undefined.

Reuses the existing internals: `getPropertyV`/`setPropertyV` (symbol-aware [[Get]]/[[Set]]),
`toPropertyDescriptor`, `Object.defineProperty`, the `in`/delete walk, `objectGetPrototypeOf`/
`objectSetPrototypeOf`, integrity ops, and the M35 `construct` machinery (extended to accept
an explicit newTarget for the instance's [[Prototype]]).

## Out of scope / M-subset deferrals
- `Reflect.set` receiver-divergence corner cases beyond the common receiver==target path
  follow the engine's existing OrdinarySet model.
- Full §10.1.6.3 DefineOwnProperty invariant matrix (already an M-subset guard in
  `Object.defineProperty`).

## Gates
`zig build` / `zig build test` / `zig build lint` (0/0) / Math+Reflect passed ↑ with 0
within-target regressions / `language/` no regression / `zig build bench` perf ok, ljs ≤ Node.
