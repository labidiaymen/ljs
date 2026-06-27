# Lumen

Website & docs: **https://lumen-lang.org**

A statically typed, compiled language with TypeScript syntax. Source is
type-checked and compiled straight to a small native binary.

## Language

Compiled static semantics — not a JavaScript runtime:

- `.ts` source, fixed static types with local inference
- `number`/`float`/`f64` floats, `int`/`i32`/`i64` integers; decimal, float,
  `0x`/`0o`/`0b` literals with `_` separators
- `//` and `/* … */` comments; `===`/`!==`
- `if`/`else if`, `while`, `do`, `for`, `for…of`, `switch`, ternary
- `enum`, `interface`, records, typed arrays
- bitwise `& | ^ ~ << >>` and exponent `**`
- nullable types (`T | null`), optional `?` fields/params, `??`, `?.`,
  `if (x != null)` narrowing
- numeric literal unions, array/object destructuring, template literals
- first-class functions, arrow functions, capturing closures
- classes: fields, constructor, `this`, methods
- `defer`; built-in `test` blocks with `expect`
- C FFI via `extern function` + library linking
- imports from a relative path or an `https://` URL (a package is just a URL)
- no prototypes, `eval`, CommonJS, or dynamic object mutation

## Install

Self-contained release, no other toolchain required:

```sh
curl -fsSL https://raw.githubusercontent.com/lumen-lang-org/lumen/main/install.sh | sh
```

Windows: download the `.zip` from the [releases page](https://github.com/lumen-lang-org/lumen/releases).

```sh
lumen compile app.ts      # build a native binary
lumen test app.test.ts    # run test blocks
```

## Imports

Import a default export from a relative file or straight from a URL:

```ts
import helpers from "./helpers.ts";
import greet from "https://raw.githubusercontent.com/lumen-lang-org/std-contrib/main/packages/hello/hello.ts";

console.log(greet("world"));
```

URL modules are fetched over HTTPS and inlined at compile time -- no package
manager, no install step. A remote module can import its own siblings with
relative paths, fetched recursively. `https://` only; remote code runs at build
time, so import from sources you trust. See [`examples/url-imports`](examples/url-imports).

## Build from source

Requires the Zig 0.16 toolchain.

```sh
zig build
zig build conformance
```

`zig build conformance` runs the manifest-driven suite under
`specs/*/conformance/`: it compiles the valid examples, runs the binaries,
compares output, and checks the expected diagnostics for the invalid ones.

## Releasing

Push a tag; CI cross-compiles every platform from one runner and uploads
self-contained archives to the GitHub Release (`.github/workflows/release.yml`):

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Development

The project uses Spec Kit; specs live under `specs/`.
