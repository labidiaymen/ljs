# Tasks 070 — Static ES Modules

- [x] T01 Lexer: add `kw_export` token + `"export"` keyword mapping.
- [x] T02 AST: `ImportEntry`, `ExportEntry`, module-only `Program` fields.
- [x] T03 Parser: `parseModule` entry + ModuleItem loop (always strict, module goal).
- [x] T04 Parser: `parseImportDeclaration` (all forms) → import entries + `requested_modules`.
- [x] T05 Parser: `parseExportDeclaration` (all forms) → export entries (+ inner decl stmt).
- [x] T06 Parser: §16.2.1.5 early errors — duplicate ExportedNames, ExportedBinding declared,
      reserved import binding names.
- [x] T07 module.zig: `ModuleRecord` + resolver indirection for live import bindings
      (`Binding.alias` / `declareImport` / `resolveAlias` in environment.zig).
- [x] T08 Interpreter: `runModule` — build module env (strict, this=undefined), link imports,
      evaluate body; namespace object for `import * as ns` / `export * as ns`; §16.2.1.6.3
      ResolveExport with a resolveSet (breaks circular re-exports).
- [x] T09 Engine: `evaluateModule` entry point (prelude script + graph loader) used by the runner.
- [x] T10 Runner: replaced the `meta.flags.module` skip with parse+link+eval + relative loader,
      cached by resolved path; kept the resolution-phase negative classification.
- [x] T11 Gates: `zig build`, `zig build test`, `zig build lint`, `zig build bench` all green.
      Language: total=44475 passed=39444→39751 (skipped 809→0), 0 regressions; 307 module tests
      now pass (module-code 268/602).

## Deferred (reported, not blocking)
- `export *` namespace GetExportedNames (star-re-export names not enumerated on the namespace).
- `[async]` / top-level-await module tests not routed through the `$DONE` sink (drain only).
- Ambiguous-export detection across multiple `export *` stars (first match wins).
- `import.meta` runtime object (parsed/early-error only).
