# Tasks — Spec 108 (`require` exports-map + `require(ESM)`)

## Unit A — `package.json` "exports" resolution
- [x] A1. `splitPackage` (bare spec → name + subpath; scoped `@x/y`), `parsePackageJson`, `packageType`.
- [x] A2. `resolveExports` (`.`/`./sub`; conditions `[node,require,default]`; subpath-map vs conditions;
        single trailing `*` wildcard) + `resolveExportTarget` (recurse conditions).
- [x] A3. Wire into `resolvePath`'s bare-specifier walk: prefer `exports` over `main`/`index`; `exports`
        present but unmapped → no legacy fallback for that package (Node gate semantics).

## Unit B — `require(ESM)`
- [x] B1. `isEsmFile` / `nearestPackageType` (.mjs → ESM, .cjs/.json → CJS, .js → nearest `"type"`).
- [x] B2. `loadModuleGraph` (parse + recursive load via a `ModuleLoader`, mirrors engine `loadGraph`).
- [x] B3. `esmResolve` (ModuleLoader.resolve = node resolution + file read).
- [x] B4. `loadEsm`: build graph → `interp_module.runModule(self, root, self.globals)` IN THE CURRENT
        realm → `drainJobs` → `moduleNamespace` → cache + return as `module.exports`.
- [x] B5. ESM→core-module bridge: `synthCoreEsm` synthesizes an ESM shim re-exporting a host core
        module (stashed on `globalThis["%coreesm:NAME%"]`) so `import x from 'node:fs'` binds.

## Unit C — supporting host/language gaps (uncovered by the target packages)
- [x] C1. `host_crypto.zig`: minimal `crypto` (randomBytes/randomFillSync/randomUUID/getRandomValues/
        randomInt/createHash[md5·sha1·sha256·sha512]); `crypto_method` NativeId + dispatch + register.
- [x] C2. `host_setup`: install the **global** `crypto` (webcrypto: getRandomValues/randomUUID) — Node ≥20
        exposes it; `uuid`'s rng uses the global.
- [x] C3. **§B.2.1 `escape`/`unescape`** global functions (were missing) — code-unit-correct via
        `string_utf16`; added to `builtins` global_fns + `interp_native` dispatch. (Pure ECMAScript.)

## Gate
- [x] G1. `zig build` + `test` + `lint` green.
- [x] G2. **`require('uuid')` works**: v4 (rng), v5 (sha1), v3 (md5), `validate`; `nanoid` works;
        `crypto.createHash('sha256').update('abc').digest('hex')` = `ba7816bf…` (correct). CJS
        (`is-odd`/`ms`/`leftpad`/`picocolors`) still work (no regression).
- [x] C4. `node:test` runner: emit TAP (`ok`/`not ok N - name` + `1..N`/`# pass`/`# fail` summary) so
        running an npm test file shows readable results (was silent).
- [x] G3. `language/` baseline → exit 0 (0 regressions; 95.1% held).
- [x] G4. `zig build bench` — perf: ok (re-recorded the machine-drifted baseline; HEAD/107 confirmed the
        change is perf-neutral — it read identical +17–35% on the degraded machine).
- [ ] G5. Spec Status → Done; commit code+spec; push.
