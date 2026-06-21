# Spec 108 — `require` honors `package.json` "exports" + loads ESM packages (`require(ESM)`)

Status: **Done** (commit pending) · Owner: Aymen

## Outcome (measured)
- **`require('uuid')` works end-to-end** — v4 (rng via global `crypto.getRandomValues`), v5 (sha1), v3
  (md5), `validate`. **`nanoid` works** too. Achieved by: `exports`-map resolution + `require(ESM)`
  (evaluate the module graph in the current realm, return the namespace) + an ESM→core-module bridge +
  a minimal `crypto` (randomBytes/UUID/getRandomValues/createHash[md5·sha1·sha256·sha512]) + the global
  `crypto` + the missing Annex-B `escape`/`unescape` globals.
- **`node:test` now prints TAP** (`ok`/`not ok N - name` + `1..N` / `# pass` / `# fail` summary) — so a
  test file that `require()`s npm packages shows real, readable results (exit 0 all-pass / 1 on failure).
- **Gate**: build/test/lint green; **`language/` 0 regressions** (95.1% held; escape/unescape are pure
  ECMAScript additions); **bench ok** (re-recorded the machine-drifted baseline — HEAD/107 itself read
  +17–35% on the now-degraded machine, confirming the change is perf-neutral).
- The existing CJS packages (`is-odd`/`ms`/`leftpad`/`picocolors`) still work (no regression).
- **Deferred**: ESM↔CJS cycles, top-level-await at require, subpath `imports` (`#x`), `crypto`
  ciphers/HMAC/keys, the `subtle` WebCrypto surface.

## Why
Spec 102's CommonJS `require` resolves `main`/`index.js` and runs CJS bodies, so pure-JS CJS packages
work (`is-odd`, `ms`, `picocolors`, `leftpad` all run today). But MODERN npm packages fail:
- **`uuid` (v9+)** → `Cannot find module` — it has NO `main`, only an `"exports"` map, and its entry is
  **ESM** (`export { … } from './v4.js'`). The resolver ignores `exports` and the loader can't run ESM.
This cycle closes both gaps so the large class of `exports`-map + ESM packages loads.

## ECMA-262 / scope
The ESM *language* (import/export grammar, linking, evaluation, namespace objects) is ECMA-262 §16.2
and ALREADY implemented (it drives the Test262 module corpus: `Parser.parseModule`, `loadGraph`,
`interp_module.runModule`, `ModuleRecord.namespace`). The Node `exports`-map resolution + the CJS↔ESM
`require(esm)` interop is the **host** loader layer (authorized Node axis). Host-only → 0 Test262
regressions by construction (the require path is installed only by `host_setup`).

## Unit A — `package.json` "exports" resolution (CJS + ESM both benefit)
In `host_require`'s resolution (`resolveAsFileOrDir` / a new `resolveExports`):
- When a package dir's `package.json` has an `"exports"` field, resolve the requested SUBPATH against
  it INSTEAD of `main`/`index.js`:
  - the `"."` entry for a bare `require('pkg')`; `"./sub"` for `require('pkg/sub')`.
  - **Conditional exports**: a string target, or a conditions object — pick the first matching of the
    ordered condition set **`["node","require","default"]`** (we resolve for the `require`/CJS world;
    `"import"` is used only to DETECT an ESM target, see Unit B). Nested condition objects recurse.
  - `"./package.json"` and literal-subpath targets resolve to the file; `*` wildcard subpaths
    (`"./lib/*": "./lib/*.js"`) supported minimally (single trailing `*`).
- Fallback unchanged: no `exports` → existing `main` → `index.js`/`index.json`.
- **`"type"`** is read here too (drives Unit B's ESM/CJS decision for a `.js` target).

## Unit B — load + run an ESM target from `require` (`require(ESM)`)
In `host_require.loadModule`, classify the resolved file:
- **CJS** (`.cjs`, or `.js` when the nearest `package.json` `"type"` ≠ `"module"`, or `.json`) → the
  existing wrapper-exec / JSON path (unchanged).
- **ESM** (`.mjs`, or `.js` under `"type":"module"`, or reached via the `exports` `"import"`/ESM target)
  → the NEW path:
  1. Build the module-record graph rooted at the resolved file — `Parser.parseModule` + a recursive
     loader (mirroring engine `loadGraph`) whose `resolve(referrer, specifier)` reuses the host node
     resolution (relative `./x`, bare → `node_modules` walk, `exports`, extensions) and READS the file.
  2. `interp_module.runModule(self, root, self.globals)` — link + evaluate **IN THE CURRENT REALM**
     (shares globals/builtins with the running program; NOT a fresh realm like the Test262 path), then
     drain microtasks (a non-TLA package settles synchronously; document TLA-at-require as a later edge).
  3. `module.exports` = `root.namespace` (the §10.4.6 namespace exotic: named exports as own props +
     `default`). So `require('uuid').v4` and `require('pkg').default` both work — matching Node's
     `require(esm)` shape.
  4. Cache by resolved path (shared graph cache so a diamond/cycle is shared; circular ESM↔CJS edges
     are out of scope this cycle — pure-ESM or ESM-leaf packages are the target).

## Files
- `src/host_require.zig` — `resolveExports` (Unit A); ESM classification + the `require(ESM)` branch in
  `loadModule`; a host `ModuleLoader` (`resolve` = node resolution + file read). Split a
  `host_esm.zig` if `host_require.zig` nears the ~2000-line budget.
- `src/interp_module.zig` / `src/module.zig` — widen visibility only if needed (`runModule` is already
  pub; `ModuleRecord`/`ModuleLoader`/`ResolvedSource` are pub). Possibly a tiny pub `loadGraph`-style
  helper if cleaner than replicating.
- No interpreter struct / NativeId changes expected (reuses existing module machinery).

## Acceptance / gate
- **`build`/`test`/`lint`/`bench` green; `language/` 0 regressions** (host-only; the module engine is
  unchanged — only the host require path is extended).
- **Functional (real npm packages, `npm install` + `ljs run`):**
  - `require('uuid').v4()` returns a v4 UUID string (ESM package via `exports`).
  - A dual/`exports`-CJS package resolves its `require` condition.
  - The existing CJS packages (`is-odd`/`ms`/`picocolors`/`leftpad`) STILL work (no regression).
- Out of scope: ESM↔CJS CYCLES, top-level-await at `require` time (drain best-effort), `import.meta`
  beyond `url`, subpath `imports` (`#x`), conditional `"browser"`, native addons.
