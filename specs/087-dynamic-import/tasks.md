# Tasks — Spec 087 Dynamic import()

- [x] T1. Move `ModuleLoader` + `ResolvedSource` to `src/module.zig` (leaf); re-export from
      `engine.zig` (keep public names). Avoids interpreter↔engine import cycle.
- [x] T2. Add `Interpreter` fields: `module_loader: ?ModuleLoader`, `module_cache:
      ?*StringHashMapUnmanaged(*ModuleRecord)`, `host_referrer_key: []const u8`.
- [x] T3. `interp_module.zig`: add `loadDynamicGraph` (parse + recursive resolve, cache by key,
      null on parse/resolve error) and `dynamicImport` (link+instantiate+evaluate → namespace
      completion). Set `host_referrer_key` (save/restore) inside `evaluateModule` per module body.
- [x] T4. `interp_expr.zig` `evalImportCall`: when a loader is set, resolve+load+settle the promise;
      else keep the legacy TypeError reject.
- [x] T5. `engine.zig`: add `evaluateWithLimitL` / `evaluateAsyncTestL` (loader + referrer params);
      originals delegate with null loader. Allocate the per-run module cache.
- [x] T6. `test262/runner.zig`: thread `dir` into `execOne`; build the loader ctx and call the L
      variants with the test path as referrer key.
- [x] T6b. Propagate the loader fields onto async/generator/async-module BODY interpreters
      (`asyncBodyThread`, `generatorBodyThread`, `asyncModuleBodyThread`) — `await import(...)` runs
      on the body thread, which otherwise sees a null loader. (Found in verification: this was the
      gap that kept the whole bucket failing until fixed.)
- [x] T7. Gate: `zig build` + `test` + `lint` + `bench`; full `language/` sweep, 0 regressions,
      0 panics. Measured: `dynamic-import` 1083→1360 passing (+277); **language 40,733 → 41,048
      (+315), 91.6% → 92.3%, 0 regressions, 0 panics; bench ok.**
