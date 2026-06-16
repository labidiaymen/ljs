# M26 — iterable `arguments` (§10.4.4 / §22.1.5) + object-literal `__proto__` (§B.3.1)

**Status:** done. Two independent runtime features.

## Part 1 — make `arguments` iterable (§10.4.4 CreateUnmappedArgumentsObject step 7)

The `arguments` exotic was a plain object with the call args as indexed string-keyed data properties
plus a non-enumerable `length`, but had NO `[Symbol.iterator]`, so `for (x of arguments)` and
`[...arguments]` threw "value is not iterable".

§10.4.4.7 installs `arguments[@@iterator]` = `%Array.prototype.values%`. We give the arguments object
that exact native (`array_values`, keyed by the realm's well-known `Symbol.iterator`, non-enumerable).

Wiring detail: the `array_values` native builds an Array Iterator over the object's `.elements`
backing store (`Object.iter.array.elements`), NOT over indexed string properties. The arguments object
is an ORDINARY object (so `Array.isArray(arguments)` stays false and indexed [[Get]]/`length` keep
reading the `properties` map), so we additionally MIRROR each arg into `ao.elements` purely as the
iterator's backing store. Because every array fast path (`iterateToList`, `destrOpen`,
`createListFromArrayLike`, …) is guarded by `kind == .array`, the ordinary arguments object correctly
routes through the real §7.4 `[Symbol.iterator]` protocol, which finds `array_values`.

Both arguments-creation sites (the ordinary-call path and the generator/async-call path in
`interpreter.zig`) now go through one helper, `makeArgumentsObject`.

## Part 2 — object-literal `__proto__` (§B.3.1 `__proto__` Property Names in Object Initializers)

In an object literal, a property `__proto__: value` whose PropertyName is the LITERAL (non-computed)
name `__proto__` — `{__proto__: v}` (identifier) or `{"__proto__": v}` (string) — sets the object's
[[Prototype]] instead of creating an own property:
- `value` is an Object → `[[Prototype]] = value`.
- `value` is null → null prototype.
- `value` is a primitive → IGNORED (prototype unchanged, no own `__proto__` property created).

NOT the proto setter (each is an ordinary own `__proto__` property):
- computed `{["__proto__"]: v}` (the name is computed),
- shorthand `{__proto__}`,
- method `{__proto__(){}}`.

**§B.3.1 Early Error:** TWO `__proto__:` colon-properties (literal name) in one object literal is a
SyntaxError — BUT this "does not apply to Object Assignment patterns" (§13.15.1). So the duplicate is
recorded at parse time (`Parser.proto_dup`, mirroring the `cover_init` cover-grammar mechanism) and
DISCHARGED when the literal is refined to an ObjectAssignment pattern by `validateAssignmentPattern`;
an undischarged residue at statement end (a real ObjectLiteral value) is the SyntaxError.

## Where
- `src/ast.zig` — `Property.is_proto` flag (set by the parser for a literal-named `__proto__:` colon
  property).
- `src/parser.zig` — `parseObjectLiteral` flags `is_proto` + records a deferred duplicate
  (`proto_dup`); `parseStmt` reports an undischarged residue; `validateAssignmentPattern` discharges
  it on refinement.
- `src/interpreter.zig` — `evalObjectLiteral` `.init` branch handles `is_proto` (sets `obj.prototype`
  for object/null, ignores primitives, no own prop); `makeArgumentsObject` builds the iterable
  arguments exotic; both call sites call it.

## Out of scope / deviations
- The arguments object remains the M-subset unmapped form (ordinary object, not the §10.4.1 mapped
  exotic); only `@@iterator` is added.
