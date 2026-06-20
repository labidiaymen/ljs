# Spec 106 — node-test wave 3: `node:test` + `timers` + `vm` + url/common (no libxev needed)

Status: In progress · Owner: Aymen

Lift the node-test number (baseline this wave: 92/290 = 31.7%) by adding the cheap, no-I/O modules
that gate the most tests. 4 independent units (parallel agents). Host-only → 0 Test262 regressions.
Agents validate against the real Node tests (`ljs run vendor/node-test/parallel/test-<x>-*.js; echo $?`).

## Unit A — `node:test` (the modern Node test runner) — ~20 tests across modules
`require('node:test')` / `require('test')`. Minimal but functional: `test(name?, opts?, fn)` (sync or
async — `fn` may return a Promise or take a `done`/`t` arg), `t.test`/subtests, `describe`/`it`,
`before`/`after`/`beforeEach`/`afterEach`, `test.skip`/`todo`/`only`, `t.mock` (minimal), `t.diagnostic`,
`t.assert` (alias the `assert` module). Run each top-level test (awaiting async via the event loop),
catch a thrown error as a FAILURE, and at end-of-run **`process.exit(1)` if any test failed** (so the
exit-code harness classifies pass/fail; all-pass → exit 0). Default export = `test`; named exports
`test/describe/it/before/after/mock`. Pass = the file's tests all pass.

## Unit B — `timers` + `timers/promises` modules — ~12 tests
`require('timers')` → `{ setTimeout, setInterval, setImmediate, clearTimeout, clearInterval,
clearImmediate }` (the existing globals, as a module; `setTimeout`/`setInterval` here return the same
ids). `require('timers/promises')` → `{ setTimeout(delay,value?,opts?)→Promise<value>,
setImmediate(value?)→Promise<value>, setInterval(delay,value?)→AsyncIterable }` built on the event
loop (study `host_timers.zig`/`runEventLoop`; a promise that resolves when a one-shot timer fires).

## Unit C — `vm` module — ~7 tests
`require('vm')`: `runInThisContext(code[,opts])` (eval in the current realm — reuse the engine's
indirect-eval path), `runInNewContext(code[,sandbox[,opts]])` + `createContext`/`isContext` (a fresh
realm/global seeded from the sandbox; a minimal context object whose globals are the sandbox props —
study `src/engine.zig`/`builtins.setup`/`host_setup` for realm creation), `compileFunction`, and a
`vm.Script` class (`new vm.Script(code)` + `.runInThisContext()`/`.runInContext()`). First cut may
share the current realm for `runInThisContext` and approximate `runInNewContext` with a child
environment; match what the failing `test-vm-*.js` actually assert.

## Unit D — `url` method gaps + `common` shim + `assert` message detail (cross-cutting)
- **url**: the 5 "value is not a function" `test-url-*` failures — add the missing `URL`/
  `URLSearchParams` methods/statics they call (`URL.canParse`, `URL.parse`, `url.format`, the legacy
  `url` module `parse`/`format`/`resolve`/`Url`, `domainToASCII`/`domainToUnicode`,
  `pathToFileURL`/`fileURLToPath`). (WPT-grade URL parsing stays out of scope; just the method surface.)
- **`scripts/node-test-common-shim.js`**: add the missing helpers tests reference (`invalidArgTypeHelper`,
  `expectsError`, `mustCall`/`mustCallAtLeast`/`mustNotCall` WITH real verification via `process.on('exit')`
  count-checks now that `process` is an EventEmitter, `mustSucceed`, `getArrayBufferViews`, `allowGlobals`,
  `hasCrypto`/`isWindows`/etc. flags). This lifts tests across ALL modules.
- **`assert`**: closer error-message formatting where cheap (the `test-assert-*` failures).

## Gate
build/test/lint/bench green; `language/` 0 regressions; re-run `scripts/run-node-tests.sh --shim`,
total should rise materially. Out of scope: `net`/`stream`/`http`/`child_process`/`worker_threads`/
`internal/*` bindings (libxev / later waves).
