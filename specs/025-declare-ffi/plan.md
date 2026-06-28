# Implementation Plan: `declare function` for FFI

## Context

Feature 009 parses `extern function NAME(params): R;` into an `extern_decl` AST
node and emits a Zig `extern fn` prototype, linked via `// @link`. Features 023
and 024 extended the marshalling (strings, `Ref<T>`) on that same node. The
declaration keyword is recognized in `Parser.parseStmt`, which dispatches
`extern` to `parseExternDecl` in `src/lumen_compiler.zig`.

Keywords in the lexer are ordinary identifiers (`.ident`), so `declare` needs no
lexer change — only a new dispatch branch in the parser.

## Approach

1. In `parseStmt`, add a branch so the `declare` keyword dispatches to the same
   `parseExternDecl` used by `extern`.
2. Generalize `parseExternDecl` to consume whichever leading keyword
   (`extern` or `declare`) and then require `function`. Everything downstream
   (params, return annotation, `extern_decl` node, FFI lowering, `// @link`
   collection in `src/lumen.zig`, marshalling) is reused unchanged.

No changes to the AST, the FFI type checker, the emitter, or the linking path.

## Files

- `src/lumen_compiler.zig` — parser dispatch + `parseExternDecl` comment/keyword.
- `specs/025-declare-ffi/` — spec, plan, tasks, examples, conformance manifest.
- `build.zig` — wire the 025 conformance manifest.
- Migrated user-facing surfaces: `examples/ffi-cpp/demo.ts`,
  `specs/009`/`specs/023` example sources, `website/index.html`,
  `website/examples.html`, `website/stdlib.html`, `README.md`.

## Verification

- `zig build` clean.
- `declare function` against libm and against a local C shim compiles, links,
  runs.
- `declare function` with `int[]` param reports `E_FFI_TYPE`.
- `zig build conformance` stays green (199 passing), with 025 cases added.
