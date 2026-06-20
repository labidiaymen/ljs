# Spec 104 — `assert` module + a `node-test` harness (measured Node-API conformance)

Status: In progress
Owner: Aymen

## Goal
Stop smoke-testing the Node host APIs by ad-hoc `ljs run` scripts; adopt **Node's own test suite** so
the host runtime gets a measured, trackable conformance % per module (the way Test262 drives the
language). Two units:
- **Unit A — `assert` module** (the dependency every Node test needs).
- **Unit B — a `node-test` harness** that runs a pinned subset of Node's `test/parallel/` files and
  reports pass/fail per module + overall.

This is host-tooling — NOT on the Test262 path; 0 Test262 regressions by construction.

## Unit A — `assert` (`require('assert')`, `node:assert`, `assert/strict`)
A host core module (`host_assert.zig`, registered in `host_require`). The default export is the
callable `assert(value[, message])` (truthy check) with methods, plus `assert.strict` (a namespace
where the loose methods alias the strict ones). Implement:
- `ok(v[,m])`, `equal`/`notEqual` (==/!=), `strictEqual`/`notStrictEqual` (SameValue-ish: `Object.is`),
  `deepEqual`/`notDeepEqual` (loose), `deepStrictEqual`/`notDeepStrictEqual` (structural, recursive,
  type-strict — arrays/objects/Map/Set/typed-arrays/dates/regex/primitives, cycle-safe),
  `throws(fn[,expected[,m]])`, `doesNotThrow`, `rejects`/`doesNotReject` (promise-returning),
  `match`/`doesNotMatch` (regex), `ifError`, `fail([m])`.
- `AssertionError` (extends `Error`, `name="AssertionError"`, carries `actual`/`expected`/`operator`/
  `code="ERR_ASSERTION"`). A failed assertion THROWS an AssertionError (so the host process exits
  non-zero on failure — the harness classifies on that).
- **Acceptance:** `assert.strictEqual(1,1)` no-throw; `assert.strictEqual(1,2)` throws AssertionError
  with `code==="ERR_ASSERTION"`; `assert.deepStrictEqual({a:[1,2]},{a:[1,2]})` no-throw;
  `assert.deepStrictEqual({a:1},{a:2})` throws; `assert.throws(()=>{throw new TypeError('x')},TypeError)`
  no-throw; `assert(0)` throws; `assert.ok(1)` no-throw.

## Unit B — `node-test` harness
Mirror the Test262 setup (gitignored, script-fetched, pinned).
- `scripts/vendor-node-test.sh` — sparse-checkout a **pinned nodejs/node tag** (an LTS, e.g. `v22.x` —
  record the exact tag in `node-test.pin`) into gitignored `vendor/node-test/`, fetching only
  `test/parallel/test-{buffer,events,util,path,url,querystring,assert,timers,process}-*.js`,
  `test/common/`, and the minimal `test/fixtures/` those need. `.gitignore` gets `vendor/node-test/`.
- The **runner**: for each selected `test/parallel/test-<mod>-*.js`, run it through the ljs host
  runtime with `cwd`/module-dir set so `require('../common')` + `require('assert')` resolve, and
  classify: **pass** = ran to completion with exit 0; **fail** = threw (AssertionError or other) /
  non-zero exit / timeout. Tally per module + overall; print a report
  (`buffer: 31/58 (53%) … TOTAL: N/M (P%)`). Cheapest correct form: a `scripts/run-node-tests.sh`
  that invokes the built `ljs run <file>` per test and checks the exit code (+ captures stderr for the
  failure reason). (A dedicated Zig runner like `test262/` is a nice future upgrade; not required now.)
- `test/common` from Node may use features ljs lacks (`process.on('exit')` for `mustCall` counts,
  internal bindings). Where `common` itself throws on load, those tests fail (accurate). Document
  which common features are the blockers (they become the next host work-items).
- **Acceptance:** `scripts/vendor-node-test.sh` fetches the subset; the runner runs it and prints a
  per-module + total pass %. A handful of pure synchronous-assert tests (e.g. several
  `test-path-*.js`, `test-buffer-*.js`) PASS. The harness is the new metric we track.

## Cross-cutting
- Unit A is engine code (host core module); Unit B is scripts + vendoring (no engine code) — independent.
- Gate: build/test/lint/bench green; `language/` 0 regressions (assert is host-only). The harness number
  itself is the new deliverable (a baseline to grow), not a pass/fail gate yet.

## Out of scope (later)
- A dedicated Zig `node-test` runner exe; `process.on`/EventEmitter-on-`process` (would unlock
  `mustCall` exit verification — a follow-up); WPT harness (separate); auto-running the Node suite in
  CI; the long tail of `common` (internal/test-only bindings).
