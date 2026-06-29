# Plan: WebAssembly compile target

`compile` gains a `--wasm` flag, threaded into `compileFile` (src/lumen.zig).
When set: reject programs containing `// @link` or the async `@cInclude("uv.h")`
marker; emit `<stem>.wasm`; build with `zig build-exe <gen>.zig -target
wasm32-wasi -O ReleaseSmall -femit-bin=<stem>.wasm`; skip the native link
collection (FFI/async are rejected, so there is nothing to link). The generated
Zig is unchanged — it already targets wasm cleanly for the language core.

Verified: a pure program compiles with `--wasm` and runs under wasmtime
(`hi wasm` / `2,4,6`); an FFI program is rejected with the friendly diagnostic.
