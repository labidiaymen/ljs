# Tasks — Spec 102 CommonJS require

DONE — merged to main, all gates green. CommonJS require works end-to-end (local/json/node_modules/
circular/path/fs/MODULE_NOT_FOUND); a real `is-odd` package (nested-requiring `is-number`) runs.
util/events deferred. Files: host_require.zig (new), runtime_types (require_fn/core_module_fn),
interp_native dispatch, interpreter (require_cache/core_module_cache), host_setup (HostCtx.script_*),
main (entry path/dir), host_buffer (makeBufferFromBytes pub).

- [x] T1. `NativeId.require_fn` (the per-module require) + `core_module_fn` (path/fs/os methods, by name).
      Second-switch unreachable arm.
- [ ] T2. `host_require.zig` (new): the module cache (`StringHashMap` resolved-path → exports Value on
      the Interpreter, or a per-run map), `resolve(dir, spec)` (core / relative / node_modules walk),
      `loadModule(self, abspath)` (read → wrap → run-in-realm → call wrapper → cache), `requireFn`
      dispatch (reads the `%dir%` own prop off `func`), `makeRequire(self, dir)` (a `.require_fn` object
      with `%dir%` + `.cache`/`.resolve`).
- [ ] T3. In-realm wrapper exec: build `(function (exports, require, module, __filename, __dirname) {…})`,
      `Parser.parseMode` → `self.run(program, self.globals)` → completion value = the wrapper fn → 
      `self.callFunction(fn, [exports, require, module, filename, dir], undefined)`. `.json` → JSON.parse.
- [ ] T4. `host_path.zig` (or in host_require): the `path` module (join/resolve/dirname/basename/extname/
      normalize/isAbsolute/relative/parse/sep/delimiter), platform-aware.
- [ ] T5. `host_fs.zig` (or in host_require): `fs` sync subset (readFileSync→Buffer/string, existsSync,
      writeFileSync, statSync, readdirSync, mkdirSync) via `self.io`/`std.Io.Dir`.
- [ ] T6. `os` (minimal) + (stretch) `util`/`events`. Core-module registry seeded with these.
- [ ] T7. `host_setup`/`engine.runHost`: inject `require`/`module`/`exports`/`__filename`/`__dirname`
      for the entry script (require bound to the script's dir). `interp_native`: dispatch the new ids.
- [ ] T8. Verify acceptance: local require, json, node_modules main, circular, path/fs, MODULE_NOT_FOUND,
      a real tiny pure-JS package.
- [ ] T9. Gate: build/test/lint/bench green; `language/`+`built-ins/` 0 regressions; present at gate.
