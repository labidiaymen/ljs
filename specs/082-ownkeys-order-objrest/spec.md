# 082 — OrdinaryOwnPropertyKeys order + object-rest CopyDataProperties

Status: Done — for-of 88.7%→90.6% (+27), for-in 78.8%→79.8% (+2), assignment 90.1%→92.6% (+21);
full `language/` 0 regressions.

## Summary
Two shared root causes in the ITERATION + DESTRUCTURING subsystem:

1. **Key enumeration order (§10.1.11.1 OrdinaryOwnPropertyKeys).** For an *ordinary* object,
   integer-index string keys (`o[2]`, `o[0]`) were enumerated in raw *insertion* order instead of
   ascending numeric order followed by the remaining string keys in insertion order. This affected
   `for-in` (`enumerateKeys`) and the canonical `ordinaryOwnKeys` collector (feeds
   `getOwnPropertyNames`, Proxy `ownKeys`, …). The code previously assumed integer-key ascending was
   "handled by the Array exotic", but ordinary objects can carry integer-index string keys too.

2. **Object rest / object spread (§7.3.25 CopyDataProperties).** The two destructuring rest paths
   (`bindForHead`/`bindPattern` BindingRestProperty §14.3.3 and `assignPattern` AssignmentRestProperty
   §13.15.5.4) and object spread `{...src}` each open-coded a raw `properties.iterator()` loop that:
   - enumerated in pure insertion order (wrong for integer keys),
   - **skipped Symbol-keyed properties** (must be copied),
   - **skipped Array exotic integer elements** (the BindingRestProperty source could be an array),
   - swallowed throwing getters instead of propagating,
   - and (BindingRestProperty) created the rest object with `[[Prototype]] = null` instead of
     `%Object.prototype%`.

## Governing clauses
- §10.1.11.1 OrdinaryOwnPropertyKeys — integer index keys ascending, then strings (insertion), then symbols.
- §6.1.7 array index — canonical numeric string of an integer in [0, 2^32 − 1).
- §7.3.25 CopyDataProperties — own enumerable (string + symbol) props, [[Get]] read, exclusion set.
- §14.3.3 BindingRestProperty, §13.15.5.4 AssignmentRestProperty.

## User scenarios (acceptance, from Test262)
- GIVEN `var o={}; o[2]='2'; o[0]='0'; o[1]='1'; o.p='p';` WHEN `for (k in o)` THEN order is `0,1,2,p`.
  (`language/statements/for-in/order-simple-object.js`)
- GIVEN a source with a getter integer key, getter string keys, and a Symbol getter WHEN
  `({...rest} = src)` THEN getters fire in [[OwnPropertyKeys]] order and the rest object contains the
  Symbol key. (`.../assignment/dstr/obj-rest-order.js`, `obj-rest-symbol-val`, `obj-rest-skip-non-enumerable`)
- GIVEN computed/non-string keys named earlier WHEN `({[k]:v, ...rest} = src)` THEN the rest excludes
  exactly those keys. (`obj-rest-computed-property*`, `obj-rest-non-string-computed-property-*`)

## Scope
In: `enumerateKeys`, `ordinaryOwnKeys`, `copyDataProperties`, both destructuring rest paths; a strict
canonical-array-index helper + an ordered-string-keys helper on `Object`.
Out: the duplicate `ownEnumerableKeys` collector in `builtin_object.zig` (Object.keys/values/entries/
assign), and `getOwnPropertyNames`/`getOwnPropertyDescriptors` direct iterators in `builtin_object.zig`
— owned by the builtins area (flagged as a follow-up; their integer-key ordering remains insertion-order).

## Success criteria
- `language/statements/for-in`, `for-of`, and `expressions/assignment` (destructuring) improve.
- Full `language/` tree: 0 regressions vs `baseline/language.json`.
- `zig build` / `test` / `lint` green; bench no regression.
