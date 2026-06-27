# Tasks: First-Class Functions

## Cycle 1: function-typed values & params (P1)
- [x] C1.1 `func_type` in types; `(T)=>R` annotation parsing.
- [x] C1.2 Named function used as a value (`&fn`), function-typed params.
- [x] C1.3 Call through a function-typed binding.
- [x] C1.4 Valid + invalid example + manifest; `zig build conformance`.

## Cycle 2: arrow functions (P2)
- [x] C2.1 Arrow lookahead + parse `(x: T) => expr`.
- [x] C2.2 Check body in isolated (no-capture) scope; infer/return type.
- [x] C2.3 Emit inline anonymous-struct function pointer.
- [x] C2.4 Valid example + manifest; `zig build conformance`.

## Cycle 3: closures (P3)
- [x] C3.1 Capturing arrows via heap environment + fat pointer (uniform fat-pointer function values; named functions + arrows + closures share one repr).

## Cycle 4: array higher-order methods (pending)
- [ ] C4.1 `map`/`filter`/`reduce`/`forEach`.
