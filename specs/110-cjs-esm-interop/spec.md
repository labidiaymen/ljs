# Spec 110 — full CJS ↔ ESM interop + ESM entry (`import` in both module systems)

Status: **Done** (commit pending) · Owner: Aymen

## Outcome
`import` and `require` now interoperate freely across CommonJS and ESM. Verified: `ljs run prog.mjs`
with top-level `import b,{n} from './b.cjs'` (CJS) + `import { v4 } from 'uuid'` (ESM pkg) all bind and
run; `require('./esm.mjs')` works; CJS scripts (`require`/`module.exports`) still run as CJS; the
`node:test` suite still runs. build/test/lint green; `language/` 0 regressions (95.1%); bench ok
(loop_mix −15.2% / loop_sum −10.6% from the spec-109 perf commit; str_build flat).

## Why
Spec 102/108 made `require()` work for both CommonJS AND ES modules. This cycle completes the matrix
from the **`import`** side so the two module systems interoperate freely (user ask: "import in both
platforms"):
- ESM `import` of a **CommonJS** (or JSON) module — bridge `module.exports` to an ESM shim.
- Running an **ESM entry file** (`ljs run x.mjs`, or a `.js` with top-level `import`/`export`) — so
  top-level `import`/`export` work in the program you run directly (not just in required modules).

## ECMA-262 / scope
The ESM language + linking is ECMA-262 §16.2 (already implemented). The CJS↔ESM *interop* and the
entry-format selection are the Node host loader layer (authorized Node axis). Host-only → 0 Test262
regressions by construction (the Test262 module path uses `evaluateModule`, never the host run path).

## Unit A — ESM imports CommonJS (`synthCjsEsm`, `host_require.zig`)
In the require(ESM) graph loader (`esmResolve`): after resolving a specifier to a file, if it is NOT an
ES module (`.cjs`, `.json`, or `.js` without `"type":"module"`), bridge it:
- evaluate it via the existing CJS `require` machinery (`loadModule`) → `module.exports`;
- stash that on `globalThis["%cjsesm:PATH%"]` (path separators normalized to `/` for the JS string
  literal) and synthesize an ESM module that `export default`s it + re-exports each own
  identifier-named property — Node's CJS-named-export interop shape.
- The core-module bridge (`synthCoreEsm`, spec 108) and this share one `esmShim` helper.
- Verified: `import b, { n } from './b.cjs'` binds `b = module.exports`, `n = exports.n`.

## Unit B — ESM entry execution (`runHostModule`, `engine.zig` + `main.zig`)
- `engine.runHostModule` — like `runHost` (install host globals → event loop → `'exit'`) but the entry
  is parsed + linked + evaluated as a MODULE graph via `host_require.runEsmEntry` (relative imports
  resolve against the entry's dir; CJS/core deps bridged; the module's namespace is the program result,
  discarded). Runs UNBOUNDED (host step limit, spec 109b).
- `main.zig` dispatch: an entry is ESM iff it ends in `.mjs` OR `looksLikeEsm(source)` (a line-based
  scan for a top-level static `import`/`export`; a dynamic `import(...)` does NOT count). Otherwise it
  runs as a CommonJS script (the default — unchanged).

## Acceptance / gate
- `build`/`test`/`lint`/`bench` green; `language/` 0 regressions (host-only).
- **Functional:** `ljs run prog.mjs` where `prog.mjs` does `import b,{n} from './b.cjs'` (CJS) AND
  `import { v4 } from 'uuid'` (ESM pkg) — all bind and run. `require('./esm-that-imports-cjs.mjs')`
  works. CommonJS scripts (`require`/`module.exports`, no import/export) still run as CJS unchanged;
  the `node:test` suite still runs.
- Out of scope: ESM↔CJS cycles, live-binding semantics across the CJS bridge (a CJS default is a
  snapshot of `module.exports` at load), `import.meta` beyond `url`, import assertions/`with`.
