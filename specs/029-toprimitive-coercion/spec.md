# 029 — ToPrimitive / OrdinaryToPrimitive coercion (§7.1.1)

## Problem
ljs never invokes a user object's `Symbol.toPrimitive` / `valueOf` / `toString` when an object
is used in an operator or coercion context. `src/abstract_ops.zig`'s `toNumber`/`toString` are
pure functions that, for an `.object`, return `NaN` / `"[object Object]"` (ToPrimitive "deferred").
`evalBinary` uses these pure helpers (and `relational`/`looseEquals`/`strictEquals`) directly, so:

- `{valueOf(){return 1}} + 1` → `NaN` (must be `2`)
- `{toString(){return "x"}} + "y"` → `"[object Object]y"` (must be `"xy"`)
- `Number(new Number(5))` / `obj * 2` etc. → `NaN`
- `{toString(){return "x"}} == "x"` → `false` (must be `true`)
- `obj < 3`, `obj - 1`, `obj++`, `obj += 1`, template `${obj}` — all wrong
- `obj[Symbol.toPrimitive]` is ignored entirely.

This is the single systematic cause behind the `unexpected_error`/`[object Object]` failures across
`expressions/{addition,subtraction,multiplication,division,modulus,exponentiation,equals,
does-not-equals,less-than,greater-than,compound-assignment,assignment,*-increment,*-decrement}`
and the `S11.x` coercion tests (toPrimitive / valueOf / `+` string-vs-number / coercion order).

## Spec clauses
- **§7.1.1 ToPrimitive(input, hint)** — if `input` is an Object: let `exoticToPrim =
  GetMethod(input, @@toPrimitive)`; if not undefined, call it with the hint string
  (`"default"`/`"number"`/`"string"`); the result must be a primitive (else TypeError). If no
  `@@toPrimitive`, default hint becomes `"number"`, then OrdinaryToPrimitive.
- **§7.1.1.1 OrdinaryToPrimitive(O, hint)** — methodNames = hint=="string" ? [toString, valueOf]
  : [valueOf, toString]. For each name: `method = Get(O, name)`; if callable, `result = Call(method)`;
  if result is not an Object, return it. If none yields a primitive → TypeError.
- **§7.1.4 ToNumber**, **§7.1.17 ToString**: for an Object, first ToPrimitive (number / string hint)
  then convert the primitive.
- **§13.15.3 ApplyStringOrNumericBinaryOperator** (`+`): ToPrimitive(lval, default) and
  ToPrimitive(rval, default) FIRST (both, left then right); if either prim is a String → string
  concat, else numeric.
- **§7.2.13 IsLessThan / relational**: ToPrimitive(number hint) on each operand, left first.
- **§7.2.15 IsLooselyEqual (`==`)**: Number/String/BigInt vs Object → ToPrimitive(object, default).

## Scope (this milestone)
- Implement `toPrimitive(value, hint)` on the interpreter (honours `@@toPrimitive`, else
  OrdinaryToPrimitive valueOf/toString). Resolve the realm's well-known `Symbol.toPrimitive`.
- Add `"toPrimitive"` to the well-known symbol set in `builtins.zig`.
- Route the coercion call sites through it: `evalBinary` (`+`, arithmetic, bitwise/shift,
  relational, `==`/`!=`), unary (`-`/`+`/`~`), prefix/postfix inc-dec, the template/`+` ToString
  path, and `Number()`/`String()`/`Boolean()`-relevant numeric conversions. Provide interpreter
  wrappers `toNumberV`/`toStringV` that ToPrimitive objects then delegate to the pure helpers.
- Preserve the hot path: primitives (number/string/boolean/undefined/null) never enter the object
  branch — they go straight through the existing pure `toNumber`/`toString`.

## Out of scope
- Wrapper-object internal `[[NumberData]]`/`[[StringData]]`/`[[BooleanData]]` slots
  (`new Number(5).valueOf()`); `new Number`/`new String` boxing is a separate milestone. (Object
  literals with `valueOf`/`toString`, which dominate Test262 coercion tests, are fully covered.)
- BigInt.

## Acceptance
- `({valueOf(){return 5}}) + 1` → `6`; `[1,2] + ""` → `"1,2"`;
  `({toString(){return "x"}}) == "x"` → `true`; `({[Symbol.toPrimitive](h){return 42}}) + 0` → `42`.
- `zig build` + `zig build test` + `zig build lint` green.
- `language/` passed ≥ 34177, **0 regressions** vs `baseline/language.json`.
- `zig build bench` "perf: ok", ljs ≤ Node (number/string fast paths unchanged).
