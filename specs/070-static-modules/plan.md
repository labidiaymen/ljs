# Plan 070 — Static ES Modules

## Approach

### Lexer (`src/lexer.zig`)
- Add `kw_export` token kind + keyword mapping for `"export"`. `import` already lexes to
  `kw_import`.

### AST (`src/ast.zig`)
- `ImportEntry { module_request, import_name (?"*"/name), local_name }`.
- `ExportEntry { export_name, module_request?, import_name?, local_name? }` (covers local
  re-name, indirect `export {a} from`, star `export * from`, namespace `export * as ns from`).
- `Program` gains module-only fields: `is_module: bool`, `import_entries`, `export_entries`,
  `requested_modules` (de-duplicated specifier list, in source order).

### Parser (`src/parser.zig`)
- `parseModule` mirrors `parseProgram` but accepts ModuleItems and is always strict, with
  module-only `this`/`new.target` rules deferred to runtime semantics. It collects import/export
  entries while still emitting ordinary `Stmt`s for the declaration bodies (so `export let x =
  1` produces both a `declaration` stmt AND an export entry).
- `parseImportDeclaration` / `parseExportDeclaration` handle every grammar form. A bare module
  specifier `import "m"` adds a requested module with no binding.
- Early errors (§16.2.1.5): collect ExportedNames + ExportedBindings + top-level declared
  names; a duplicate ExportedName → SyntaxError; an ExportedBinding not in the declared set →
  SyntaxError. `import`/`export` outside the module top level is rejected by only entering the
  module-item parse from `parseModule`.
- `Parser.parseModule(arena, src)` public entry; `parseMode` (script) untouched, so the
  parallel dynamic-`import()` work and all script tests are unaffected.

### Interpreter (`src/interpreter.zig`) + new `src/module.zig`
- A `ModuleRecord` (resolved path, parsed Program, environment, status, namespace object,
  exports map). The loader (in the runner) builds the dependency graph; the interpreter links
  and evaluates.
- Link: create the module environment (a var scope, strict), declare every top-level
  lexical/var/function name, then create indirect "import bindings" that alias the exporting
  module's binding (live binding: the imported name resolves through to the source binding's
  cell). Implemented by resolving the source `*Binding` pointer lazily at read time via a small
  indirection, OR by sharing the same environment slot. We use a resolver map name→source.
- `import * as ns` builds a module namespace object whose own properties read through to the
  source bindings.
- Evaluate: depth-first over requested modules (each once), then run the body via the existing
  `run` machinery on the module env with `this` = undefined, strict = true.

### Runner (`test262/runner.zig`)
- Replace the `meta.flags.module` skip with: resolve the test file's directory, build a loader
  closure that reads sibling files, parse+link+evaluate the root module, classify like a normal
  test (parse-negative → SyntaxError; positive → normal completion). `[async]` modules keep the
  `$DONE` drain.

## Constitution Check
- Correctness-leads: this advances real conformance (un-skips 809 tests). No perf hot path is
  on the module link path (only runs for module tests).
- Perf no-regression: script evaluation path (the bench corpus) is untouched — `parseMode` and
  `run` for scripts are unchanged; module code lives behind `is_module`/`runModule`. Bench gate
  must stay green.

## Risk / design calls
- Live bindings via an indirection record rather than rewriting Environment — keeps the hot
  declarative-scope path unchanged.
- If full link/eval proves too large, land grammar + early errors + the loader un-skip so the
  syntax/early-error subset (the majority of module-code) passes, and defer deep linking.
