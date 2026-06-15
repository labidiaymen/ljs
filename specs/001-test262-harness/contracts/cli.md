# Contract: Command-Line Interfaces

M0 exposes two interfaces: the engine CLI (`ljs`) and the harness build step
(`zig build test262`). These are the project's external contracts for this feature.

## 1. Engine CLI — `ljs`

### `ljs eval "<source>"`
Evaluate a source string and print its observable result.

| Input | Behavior | Stdout | Exit code |
|-------|----------|--------|-----------|
| Valid expression, normal completion | evaluate | spec string form of the value (e.g. `3`, `"hi"`, `true`, `undefined`, `null`) | `0` |
| Source throws | evaluate | `Uncaught <ErrorName>: <message>` to stderr | `1` |
| Syntax error | parse fails | `SyntaxError: <message>` to stderr | `1` |

### `ljs run <file>`
Same semantics as `eval`, reading source from `<file>`. Missing file → clear error, exit `2`.

### Examples
```
$ ljs eval "1 + 2"
3
$ ljs eval "2 * (3 + 4)"
14
$ ljs eval "1 +"
SyntaxError: unexpected end of input        # stderr, exit 1
```

> The set of expressions guaranteed correct at M0 is the "trivial set" (≥20 cases) covered by
> `tests/eval_test.zig` (SC-005): numeric/string/boolean/null literals, unary `+ - !`, binary
> `+ - * / %`, grouping, and basic comparison.

## 2. Harness — `zig build test262 -- [options]`

Run the conformance harness over a subset and print a report.

| Option | Meaning | Default |
|--------|---------|---------|
| `--path <dir>` | restrict the run to a subdirectory of the vendored suite (FR-008) | whole suite |
| `--mode <strict\|sloppy\|both>` | restrict run mode | `both` |
| `--baseline <file>` | compare against a stored baseline; non-zero exit on regression (FR-009) | none |
| `--update-baseline <file>` | write/refresh the baseline from this run | — |
| `--report <file>` | also write the JSON report (see report-schema.json) | stdout only |
| `--step-limit <n>` | interpreter step cap / watchdog (research D8) | implementation default |

### Output (human summary)
```
Test262  subset=test/language/expressions/addition  commit=<short-hash>
  total=NNN  passed=NN  failed=NN  skipped=NN  conformance=NN.N%
  regressions=0  improvements=0          # only when --baseline given
```

### Exit codes
| Code | Meaning |
|------|---------|
| `0` | run completed; no regression vs baseline (or no baseline given) |
| `1` | regression detected vs `--baseline` (FR-009) |
| `2` | setup error (vendored suite missing / wrong commit / unreadable) |

> A non-zero exit from a *test* (a failing test) does **not** fail the harness process — only a
> regression vs baseline or a setup error does. One crashing test never aborts the run (FR-006).

> **M0 baseline format:** `--update-baseline` currently writes only a flat JSON array of passing
> ids (`["path#mode", …]`) — a subset of [report-schema.json](./report-schema.json)'s
> `passing_ids`. The full object schema (counts, `pinned_commit`, `improvements`, …) is adopted
> in a later milestone. `improvements` are not yet computed/printed.

## 3. Benchmark — `zig build bench -- [options]`

Run the shared benchmark set on **both** ljs and Node.js and report the comparison (US4,
constitution Principle IV).

| Option | Meaning | Default |
|--------|---------|---------|
| `--reps <n>` | timed repetitions per case (after warm-up) | implementation default |
| `--update-baseline` | write `bench/baseline.json` from this run | off |
| `--node <path>` | Node binary to compare against | `node` on PATH |
| `--tolerance <pct>` | noise band for the ljs-vs-self regression check | e.g. 15 |

### Output (human summary)
```
Benchmark            ljs_ms    node_ms   ratio(ljs/node)   vs-baseline
arith-loop           1240.0    3.1       400.0x            +2.1%  ok
fib-ish              980.5     2.4       408.5x            -0.4%  ok
string-concat        310.2     1.9       163.3x            REGRESSION (+38%)
```
When Node is unavailable: `node_ms` and `ratio` show `n/a`; ljs is still timed (FR-016).

### Exit codes
| Code | Meaning |
|------|---------|
| `0` | ran; no ljs-vs-self regression beyond tolerance |
| `1` | ljs perf regression vs `bench/baseline.json` (FR-015) |
| `2` | setup error (no benchmark cases / ljs build missing) |

> The large `ratio` to Node is **expected and reported, never a hard fail** at this stage
> (track + no-regression). Only an ljs-vs-its-own-baseline regression fails the gate.
