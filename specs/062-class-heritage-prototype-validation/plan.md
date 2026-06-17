# Implementation Plan: Class heritage `prototype` validation (M74 / 062)

## Approach

`src/interpreter.zig` `evalClass`, the heritage `.object` arm (~2182): replace the
"object-only, silently ignore non-object" prototype read with a §15.7.14-faithful switch.

```zig
if (so.get("prototype")) |pv| switch (pv) {
    .object => |po| super_proto = po,
    .null => {}, // §15.7.14: a null protoParent is valid — no prototype link, F is still the parent ctor
    else => return self.throwError("TypeError", "Class extends value does not have a valid prototype property"),
};
```

A property that is ABSENT (`so.get` returns Zig-null) is left unchanged (current behavior) — only
a PRESENT primitive value throws. `null`/object behavior is unchanged from today.

## Files touched
`src/interpreter.zig` (evalClass heritage arm only).

## Risks
- LOW. Only adds a throw for a present primitive `prototype`; object/null/absent paths unchanged.
  Regression guards in spec.md + the conformance gate cover the valid cases.

## Constitution Check
- Correctness leads: §15.7.14. ✔  • Perf: definition-time only. ✔
