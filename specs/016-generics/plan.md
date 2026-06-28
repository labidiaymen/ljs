# Implementation Plan: Generics (Monomorphized)

**Branch**: `tjs-native` (milestone 016) | **Date**: 2026-06-28 |
**Spec**: [spec.md](./spec.md)

## Summary

Add generic functions, classes, and interfaces plus `Array<T>` sugar by
monomorphizing each generic body per concrete type-argument tuple. The key idea
is source-to-source specialization driven by the checker: type parameters never
reach the backend. A new `type_param` type variant represents an unresolved
parameter inside a generic body; substitution replaces it with a concrete type
before the existing checker/emitter run on the specialized copy.

## Technical Context

**Language/Version**: Zig 0.16.0 (compiler + generated backend).

**Touched files**:
- `src/lumen_types.zig` — `type_param` variant; mangling and `zigName`/`same`
  coverage (the latter as a defensive error path).
- `src/lumen_ast.zig` — `type_params` on `FunctionDecl`/`ClassDecl`/`TypeDecl`;
  `type_args` on the `call` and `new_expr` nodes; a `generic` marker.
- `src/lumen_lexer.zig` — none expected (`<`/`>` already lex as `cmp`).
- `src/lumen_compiler.zig` (parser) — parse `<...>` type-parameter lists on
  declarations, explicit `<...>` type-argument lists on calls / `new`, and
  `Array<T>` / `Name<...>` in annotations.
- `src/lumen_check.zig` — the monomorphization engine: collect generic decls,
  infer/validate type arguments, build specialized copies, rewrite call sites,
  and check the specialized copies; substitute type parameters into interface
  field types.

**Reuse**: the existing `funcStructName`-style mangling, `typeFromAnnotation`,
`ensureAssignable`, `exprType`, `declareFunction`/`checkFunctionBody`,
`classes`/`type_decls` registries, and the concrete emitter — specialized copies
flow through the normal concrete paths.

## Approach

1. **Type + AST**: add `type_param: []const u8`. Add `type_params` (a
   `[][]const u8`) to function/class/type decls and `type_args` (a `[][]const u8`
   of concrete annotation strings) to call / `new` nodes.
2. **Parser**:
   - After a function/class/interface name, optionally parse `<T, U, ...>` into
     `type_params`. Inside such a declaration, annotations naming a type
     parameter parse as ordinary identifiers (already supported).
   - In `parseTypeAnnotation`, accept `Array<X>` (sugar -> `X[]`) and
     `Name<args...>` (recorded canonically as `Name<arg,arg>` for the checker).
   - At call sites and `new`, use bounded lookahead to recognize an explicit
     `<...>` type-argument list before `(`; otherwise leave `<` to comparison
     parsing.
3. **Checker monomorphization**:
   - Pre-pass: register generic functions/classes/interfaces separately from
     concrete ones (they are *not* declared into `funcs`/`classes` for direct
     use; only their specializations are).
   - On a `call` to a generic function: determine the type-argument tuple
     (explicit list, else infer by unifying each parameter's annotation against
     the argument's `exprType`). Validate counts/consistency. Look up or build a
     specialized `FunctionDecl` (params/return substituted), declare + check it
     once, cache by mangled key, rewrite the call's `emit_name`, and return the
     substituted return type.
   - On `new C<...>(...)`: build/cache a specialized class (mangled name), check
     it once, and treat the value as that concrete class type.
   - `Name<...>` interface annotations resolve to a specialized record `type`
     (mangled name) declared on demand.
   - Append all specialized decls to `program.stmts` so the emitter outputs them;
     skip the original generic decls during emit.
4. **Emitter**: emit nothing for a declaration still carrying `type_params`
   (generic originals); specialized copies are plain decls and already emit.

## Constitution Check

- TypeScript source is the product: generics use standard TS syntax; the backend
  stays an artifact (monomorphic Zig). Pass.
- Static checking preserved: every specialization is fully checked with concrete
  types; inference/constraint errors diagnose before native build. Pass.
- No new dynamic semantics: monomorphization is compile-time only. Pass.

## Milestone Strategy

Small slices, building + running a scratch program after each:
1. Generic functions: single type param, inferred; then multiple params and
   explicit `f<T>(...)`.
2. `Array<T>` sugar.
3. Generic classes (`new C<T>(...)`), then generic interfaces.
4. Conformance: valid + invalid examples, manifest, wire `build.zig`; keep
   `zig build conformance` green.

If full generic classes/interfaces prove infeasible within the cycle, ship
generic functions (+ `Array<T>`) soundly and defer the rest, keeping the tree
green.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Specialization pass in the checker | Reuses the entire concrete check+emit pipeline unchanged | A backend with generic Zig (`anytype`/comptime) would leak Zig semantics into diagnostics and complicate type errors |
