# Robustness Benchmark

This benchmark compares one deterministic workload in two implementations:

- `robust-main.ts`: Lumen source compiled to a native binary
- `robust-main.node.js`: equivalent Node.js source

The workload exercises imports, typed arrays, object literals, field access,
functions, loops, Math helpers, String/Array helpers, exceptions, and console
output.

Run it from the repository root:

```sh
node benchmarks/robustness/run.js
```

Optionally pass the number of timing rounds:

```sh
node benchmarks/robustness/run.js 30
```

The runner builds `lumen`, compiles the Lumen source once, verifies that native
and Node outputs match, then reports average process execution time for each.
