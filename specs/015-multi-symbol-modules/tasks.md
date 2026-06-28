# Tasks: Multi-Symbol Modules

## Slice 1: named import + export parsing (P1)
- [x] T1.1 `ImportSpec` becomes default/named kinds; `parseImportSpec` accepts
  `import { a, b } from "..."` for local and URL specs.
- [x] T1.2 Export parsing: `export function/const/let NAME` and `export { ... }`
  list helpers; export-name collection.

## Slice 2: emission + validation (P2)
- [x] T2.1 Emit named exports as plain declarations (strip `export `); drop
  `export { ... }` lists; keep default rename.
- [x] T2.2 Validate named imports against module exports; `E_MISSING_EXPORT`
  (including deduped/already-inlined modules).
- [x] T2.3 Scratch program: multi-symbol named import compiles + runs.

## Slice 3: conformance (P3)
- [x] T3.1 Valid examples: named functions + const import; `export { }` list.
- [x] T3.2 Invalid examples: missing export, duplicate binding.
- [x] T3.3 Manifest + wire into `build.zig`; `zig build conformance` green,
  existing suite still green.
