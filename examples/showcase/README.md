# Lumen Showcase Examples

Small standalone programs demonstrating the V1 language surface.

Build and run an example:

```sh
zig build
./zig-out/bin/lumen compile examples/showcase/inventory.ts
./inventory
```

Run the test example:

```sh
./zig-out/bin/lumen test examples/showcase/math.test.ts
```

| File | Features shown |
|------|----------------|
| `inventory.ts` | enums, interfaces, arrays of records, `for...of`, template literals |
| `higher-order.ts` | function-typed params, named functions as values, arrow functions, ternary |
| `config.ts` | optional `?` fields, `??` coalescing, `if (x != null)` narrowing, `defer` |
| `math.test.ts` | `test "..." { ... }` blocks with `expect(...)` |
