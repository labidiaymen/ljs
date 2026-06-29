# Feature Specification: WebAssembly compile target

**Feature Branch**: `main` (milestone 030) | **Status**: Draft

**Input**: `lumen compile --wasm <file.ts>` builds the program to a
`wasm32-wasi` `.wasm` module instead of a native binary, so Lumen programs can
run in a browser (via a WASI shim) or any WASM runtime. This is the enabler for
a client-side playground: a small service compiles to wasm, the browser runs it.

## Scope

- `--wasm` flag on `lumen compile`. Emits `<stem>.wasm`, targets `wasm32-wasi`,
  optimized with `ReleaseSmall`.
- The pure-language core (control flow, generics, classes, strings, arrays,
  Map/Set, error handling, `console`) compiles and runs under WASI.

Out of scope (rejected for wasm with a clear error): C FFI (`// @link`) and
async/await (the libuv event loop) — neither has a wasm story yet. Networking
(`httpGet`/`serve`) likewise does not apply under WASI preview1.

## Requirements

- **FR-001**: `lumen compile --wasm f.ts` MUST produce `f.wasm` for
  `wasm32-wasi`, runnable under a WASI runtime; `console.log` output reaches
  stdout (`fd_write`).
- **FR-002**: A program using `// @link` (C FFI) or async/await with `--wasm`
  MUST fail with a clear "the wasm target does not support C FFI or async yet"
  diagnostic rather than a backend link error.
- **FR-003**: Native builds (without `--wasm`) MUST be unchanged.

## Success criteria

- **SC-001**: A pure program (strings + array methods + console) compiles with
  `--wasm` and prints correctly under wasmtime.
- **SC-002**: An FFI/async program with `--wasm` is rejected with the friendly
  diagnostic.

## Notes

Verification is example-based (a WASM runtime is needed to execute), not part of
the offline conformance gate — mirroring the FFI examples.
