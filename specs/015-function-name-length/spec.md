# M14 — Function `name`/`length` own properties + class method/accessor attributes

## Goal
Give every function object the `name` (§20.2.4.2) and `length` (§20.2.4.1) own data
properties, and fix class method/accessor/static members to be **non-enumerable**
(§15.7.x). Function `name`/`length` is one of the most-asserted facts in Test262 (every
`verifyProperty`/`propertyHelper` test on a function touches them); the class enumerability
fix unblocks `verifyProperty` on every class member.

## Scope (ECMA-262, no host APIs)

### `length` (§20.2.4.1)
- Own data property, descriptor `{ writable:false, enumerable:false, configurable:true }`.
- Value = ExpectedArgumentCount: the count of leading FormalParameters BEFORE the first one
  that has a default initializer, is a BindingPattern (destructuring), or is the rest element.
- Applies to: function declarations/expressions, arrows, object/class methods, accessors
  (getter → 0, setter → 1), generators, async, async generators, the class constructor
  (constructor param count), and bound functions (`max(0, target.length - boundArgs.length)`).

### `name` (§20.2.4.2 + SetFunctionName §10.2.9 + NamedEvaluation §8.4)
- Own data property, descriptor `{ writable:false, enumerable:false, configurable:true }`.
- Sources:
  - function/generator/async **declaration** → the declared name.
  - **named** function/class expression → its name.
  - **method / accessor** (class or object) → the property-key string; getter `"get x"`,
    setter `"set x"`; symbol key `"[desc]"` (or `""` for a description-less symbol).
  - **class** → the class name; an anonymous class expression assigned to a binding gets the
    binding name (NamedEvaluation).
  - **anonymous** function/arrow/class via NamedEvaluation: `var/let/const f = <anon>`,
    assignment `f = <anon>` to an identifier, object-literal property value `{f: <anon>}`,
    default-value initializer. A bare anonymous function not in a naming context → `""`.
  - **bound** function → `"bound " + target.name`.

### Class member attributes (§15.7.x)
- Class methods / generator methods / async methods / async-gen methods / accessors
  (instance on `.prototype`, static on the constructor) are **non-enumerable**
  (`enumerable:false`; methods writable:true configurable:true; accessors configurable:true).
- Class **fields** are data `{ writable:true, enumerable:true, configurable:true }`.
- **Object-literal** methods/accessors are UNCHANGED (enumerable — normal object properties).

## Out of scope / deferred
- Per-native `length` tuning (e.g. `Object.defineProperty.length===3`): natives get a correct
  `name` (cheap, the name is already known) but the full per-native arity table is deferred —
  a separate large surface that does not block the user-function leverage. Native `name` only.
- Computed-key symbol `name` for object/class members keyed by a Symbol with a description
  is implemented; a fully spec-exact `"[Symbol.iterator]"`-style for well-known symbols matches
  because the description is `Symbol.iterator`.

## Gates
Primary: `language/` harness passed ≥ 19924 (expect a large gain). Continuity:
`language/expressions` ≥ 9728. Bench: no ljs-vs-self regression (functions created outside
hot loops; name/length adds 2 inserts per function object only at creation).
