# Implementation Plan: Multi-Symbol Modules

**Branch**: `tjs-native` (milestone 015) | **Date**: 2026-06-28 |
**Spec**: [spec.md](./spec.md)

## Summary

Extend the CLI source inliner so a module can declare several named exports and
importers can pull in any subset by name. Resolution stays purely textual: the
inliner strips `export ` keywords so named exports become ordinary top-level
declarations, drops `export { ... }` re-export lists, validates that named
imports refer to real exports, and recurses through local + URL imports exactly
as before. The type checker then validates the combined translation unit with
its normal top-level scope rules — including duplicate bindings.

## Technical Context

**Language/Version**: Zig 0.16.0.

**Touched files**:
- `src/lumen.zig` — `ImportSpec` (default vs named kinds), `parseImportSpec`,
  named-export parsing/emission, export collection, missing-export validation,
  and the `E_MISSING_EXPORT` diagnostic.

**Reuse**: the existing `appendExpandedSource` recursion (dedup, cycle, URL
resolution, test stripping), `appendExportDefaultFunction` default rename, and
the checker's existing `E_DUPLICATE_BINDING` top-level scope rules.

## Approach

1. **Parse imports**: `ImportSpec` carries a tagged `kind` — `default` (binding
   name) or `named` (list of names). `parseImportSpec` accepts both
   `import x from "..."` and `import { a, b } from "..."` (local + URL specs).
2. **Parse exports**: helpers recognize `export function/const/let NAME` (and
   return the name + `export `-stripped declaration) and `export { a, b }` lists.
3. **Validate named imports**: before/instead of re-emitting a module, collect
   its export names and require each requested binding to exist, else
   `E_MISSING_EXPORT` (checked even for already-inlined deduped modules).
4. **Emit**: strip `export ` from named-export declarations and emit them as
   plain top-level declarations; drop `export { ... }` lists; keep the default
   export rename. The combined program is handed to the checker unchanged.
5. **Diagnostics**: map `error.MissingExport` to `E_MISSING_EXPORT`. Duplicate
   bindings (import-vs-import or import-vs-local) fall out of the checker's
   existing `E_DUPLICATE_BINDING`.

## Risks

- Pre-existing `native.invalid.import-named` expected `E_UNSUPPORTED_IMPORT`;
  named imports are now valid, so that case is repointed to a missing export and
  now asserts `E_MISSING_EXPORT`.
