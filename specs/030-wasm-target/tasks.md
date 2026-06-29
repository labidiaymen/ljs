# Tasks: WebAssembly compile target

- [x] T1 `--wasm` flag on `compile`, threaded into `compileFile`.
- [x] T2 Reject `// @link` (FFI) and async (`@cInclude("uv.h")`) under `--wasm`.
- [x] T3 Emit `<stem>.wasm`; build `-target wasm32-wasi -O ReleaseSmall`; skip
  link collection.
- [x] T4 Usage text mentions `[--wasm]`.
- [x] T5 Verify: pure program runs under wasmtime; FFI/async rejected.
