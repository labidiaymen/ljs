# Feature Specification: Multi-Symbol Modules

**Feature Branch**: `tjs-native` (milestone 015) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Extend the module system beyond a single default export per file.
Builds on the local + URL import inliner (001, 012): modules may now declare
several named exports and importers may pull in any subset by name.

## Scope (V1)

Module-level export and import forms, resolved by the CLI source inliner before
type checking:

- `export function NAME(...) { ... }`
- `export const NAME: T = ...` (and `export let NAME ...`)
- `export { a, b, c }` re-export lists for already-declared symbols
- `import { a, b } from "./mod.ts"` named imports
- `import { a } from "https://host/mod.ts"` named imports from URLs

All previously supported behavior is preserved: default imports
(`import name from "./mod.ts"`), local and `https://` URL specifiers, recursive
URL-relative imports, dedup and cycle detection, and stripping of `test "…"`
blocks from imported modules.

Named imports must name a real export of the target module; the imported
bindings become ordinary top-level symbols and are type-checked like any other
declaration. Importing two symbols that collide with each other or with a local
declaration is a duplicate-binding error.

Out of scope this cycle: import aliasing (`import { a as b }`), namespace
imports (`import * as ns`), re-export from another module
(`export { x } from "./other.ts"`), and exporting types/enums/classes by name.

## Requirements

- **FR-001**: A module may declare any number of named exports via
  `export function`, `export const`/`export let`, and `export { ... }` lists.
- **FR-002**: `import { a, b } from "./mod.ts"` brings the named exports `a` and
  `b` into scope as top-level bindings with the module's declared types.
- **FR-003**: Named imports work from `https://` URLs and through recursive
  URL-relative imports, exactly as default imports do.
- **FR-004**: Default imports, dedup, import-cycle detection, duplicate-import
  detection, and `test` block stripping for imported modules all keep working.
- **FR-005**: Importing a name the target module does not export reports
  `E_MISSING_EXPORT`.
- **FR-006**: A named import that collides with another binding (another import
  or a local declaration of the same name) reports `E_DUPLICATE_BINDING`.
- **FR-007**: Unsupported import shapes (bare specifier, non-`.ts`, `http://`,
  namespace `*`) still report `E_UNSUPPORTED_IMPORT`.

### Diagnostics
Adds `E_MISSING_EXPORT`. Reuses `E_DUPLICATE_BINDING`, `E_UNSUPPORTED_IMPORT`,
`E_IMPORT_NOT_FOUND`, `E_IMPORT_CYCLE`, `E_DUPLICATE_IMPORT`.

## Success Criteria

- **SC-001**: A program importing several named symbols (functions and consts)
  from a local module compiles and the native binary prints expected results.
- **SC-002**: An `export { a, b }` re-export list and a named import combine to
  produce a working binary.
- **SC-003**: A missing-export import and a name collision each fail before
  native build, with the documented diagnostics.
- **SC-004**: `zig build conformance` passes with the feature 015 manifest and
  the existing suite stays green.

## Notes

Resolution is purely textual in the CLI inliner (`src/lumen.zig`): `export `
keywords are stripped so named exports become ordinary top-level declarations in
the combined program, `export { ... }` lists are dropped (their declarations
appear on their own lines), and the default export keeps the importer-chosen
binding name. Because every module is inlined into one translation unit, the
type checker validates the imported bindings — including duplicate names — with
its normal top-level scope rules.
