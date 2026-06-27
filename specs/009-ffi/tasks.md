# Tasks: C FFI

- [x] T1 Add `extern_decl` to the AST; parse `extern function name(params): R;`.
- [x] T2 Register externs (hoisted) in the function table; restrict to C-safe
  scalar types (`E_FFI_TYPE`).
- [x] T3 Emit `extern fn name(...) R;` into the generated Zig.
- [x] T4 Link via `// @link <lib>` pragma and `--link <lib>` flag; bare names →
  `-l`, path-like tokens → verbatim (objects/archives).
- [x] T5 Working libm example + invalid type example + C++ `extern "C"` demo;
  manifest + `zig build conformance`.
