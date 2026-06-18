# Spec 070 — Static ES Modules (ECMA-262 §16.2)

Status: Done — language passed 39444→39751 (skipped 809→0), 307 module tests now pass, 0 regressions.

## Summary
Implement the static module grammar (`import`/`export` declarations), module linking and
evaluation with live bindings, and a minimal Test262 module loader so the 809 currently-SKIPPED
`[module]` tests under `vendor/test262/test/language/` can run. This is the in-scope module
LANGUAGE part (ECMA-262 §16.2 Modules). General Node host APIs (`require`, `fs`, host timers)
stay out of scope; the module loader is a permitted minimal test-harness loader that resolves a
relative specifier to a sibling file on disk.

## Governing clauses
- §16.2.1 Module Semantics — ModuleItemList, ImportDeclaration, ExportDeclaration.
- §16.2.1.5 Static Semantics: Early Errors (duplicate exported names, exported binding must be
  declared, `import`/`export` only at module top level).
- §16.2.1.6 Source Text Module Records — ModuleDeclarationInstantiation (link), ResolveExport,
  GetExportedNames, InitializeEnvironment, Evaluation.
- §16.2.2 Imports / §16.2.3 Exports grammar.
- §9.4.1 module top-level `this` is undefined; module code is always strict.

## In scope
- Lexer: `export` keyword token (`import` already exists).
- Parser: a Module goal (`parseModule`) producing a ModuleItem list:
  - `import` forms: `import "m"`, `import d from "m"`, `import {a, b as c} from "m"`,
    `import * as ns from "m"`, `import d, {…} from "m"`, `import d, * as ns from "m"`.
  - `export` forms: `export {a, b as c}`, `export {a} from "m"`, `export * from "m"`,
    `export * as ns from "m"`, `export default <expr|func|class>`,
    `export var|let|const|function|class …`.
  - Early errors: duplicate export names, exported binding name not declared, `import.meta`
    placement, reserved binding names (`import eval`, `import arguments`).
- AST: import/export entry records carried on `Program` (module-only fields).
- Interpreter: a `runModule` path that builds the module environment (strict, `this` =
  undefined), links imports to the exporting module's live bindings, and evaluates the module
  body in dependency order, caching by resolved path.
- Runner (`test262/runner.zig`): when `meta.flags.module`, parse+link+evaluate as a Module
  instead of skipping; resolve relative specifiers from the test file's directory and read+parse
  recursively, caching by resolved path. Keep `[async]` `$DONE` handling.

## Out of scope
- Node host APIs (`require`, `fs`/`http`/`net`/`process`/`Buffer`, host timers).
- `import.meta` runtime object (parsed/early-error only; no host meta).
- Import attributes / JSON modules / top-level await ordering subtleties beyond what the
  corpus's positive linking tests exercise (await machinery already exists).

## User scenarios (Given / When / Then)
1. Given a `[module]` parse-negative test (`export { unresolvable };`), When run as a Module,
   Then the parse fails with SyntaxError → PASS (was SKIP).
2. Given a duplicate-export module (`export function f(){} export function* f(){}`), When
   parsed, Then a SyntaxError early error → PASS.
3. Given `import { x as y } from './self.js'; export let x = 23;` (live binding), When linked
   and evaluated, Then `y` reflects `x` (TDZ before init, value after) → PASS.
4. Given `import * as ns from './m.js'`, When evaluated, Then `ns` is the module namespace
   exotic object exposing the exported names.
5. Given a non-module test in the existing baseline, When the run completes, Then it still
   passes (0 regressions).

## Success criteria
- The 809 `[module]` tests are no longer SKIPPED — they parse/link/evaluate and classify.
- Module conformance up (total/passed of `language` rises; module-tests passed > 0).
- 0 regressions on the previously non-skipped `language` baseline (`baseline/language.json`).
- `zig build`, `zig build test`, `zig build lint` green; `zig build bench` no regression.
