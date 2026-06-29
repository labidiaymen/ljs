<h1 align="center">Lumen</h1>

<p align="center">
  <b>Write TypeScript syntax. Ship a native binary or a single wasm file.</b><br>
  No Node. No runtime. No GC pauses.
</p>

<p align="center">
  <a href="https://lumen-lang.org/play"><b>▶ Try it in your browser</b></a> ·
  <a href="https://lumen-lang.org/examples">Examples</a> ·
  <a href="https://lumen-lang.org/packages">Packages</a> ·
  <a href="https://lumen-lang.org">Website</a>
</p>

<p align="center">
  <img alt="install" src="https://img.shields.io/badge/install-curl%20%7C%20sh-black">
  <img alt="targets" src="https://img.shields.io/badge/targets-native%20%2B%20wasm-blue">
  <img alt="npm" src="https://img.shields.io/npm/v/@lumen-lang/markdown?label=%40lumen-lang%2Fmarkdown">
</p>

---

Lumen takes the TypeScript syntax you already know and compiles it ahead-of-time
to a native executable or **one self-contained WebAssembly module**. It is
statically typed, with no interpreter shipped alongside it.

```ts
// hello.ts
function greet(name: string): string {
  return `Hello, ${name}!`;
}
console.log(greet("world"));
```

```sh
curl -fsSL https://lumen-lang.org/install.sh | sh   # install
lumen compile hello.ts && ./hello                   # native binary
lumen compile --wasm hello.ts                       # one .wasm file
```

### Packages are just URLs, and they can be *real*

Import straight from a URL (no package manager, no lockfile). Some packages even
embed a C library (QuickJS, SQLite) into the wasm, so the whole program is one
file whose only imports are WASI:

```ts
import * as qjs from "https://lumen-lang.org/package/std-contrib/quickjs/quickjs.ts";
qjs.open();
console.log(qjs.evalNumber("21 * 2 + Math.sqrt(16)"));   // 46
```

### Write a library in Lumen, ship it to npm

The Markdown renderer in `std-contrib` is written entirely in Lumen, then
compiled to a zero-dependency wasm package on npm that **outpaces the popular
pure-JS libraries**:

```sh
npm install @lumen-lang/markdown
```

```js
import { render } from "@lumen-lang/markdown";   // 0 dependencies
render("# Hi\n\n**bold**");                       // "<h1>Hi</h1>\n<p>…"
```

> ~6,700 renders/sec: ~2.4× markdown-it, ~5× marked, from TypeScript syntax.

## Language

Compiled static semantics, not a JavaScript runtime:

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
- C FFI via `declare function` (TypeScript-valid; `extern function` also works) + library linking
- imports from a relative path or an `https://` URL (a package is just a URL)
- no prototypes, `eval`, CommonJS, or dynamic object mutation

## Install

Self-contained release, no other toolchain required:

```sh
curl -fsSL https://lumen-lang.org/install.sh | sh
```

Windows: download the `.zip` from the [releases page](https://github.com/lumen-lang-org/lumen/releases).

```sh
lumen compile app.ts      # build a native binary
lumen watch app.ts        # rebuild + re-run on every change
lumen test app.test.ts    # run test blocks
```

## Watch mode: `lumen watch`

Keep an edit loop running. `lumen watch app.ts` builds the program, runs it, and
then rebuilds and re-runs it whenever the entry file or any of its local imports
changes (the previous run is restarted automatically):

```sh
lumen watch app.ts            # rebuild and re-run on change
lumen watch --no-run app.ts   # rebuild only, do not execute
```

A build error prints the same diagnostic as `lumen compile` and leaves the last
good run going; fixing the error rebuilds. Press Ctrl-C to stop. Remote
`https://` imports are not watched.

## Getting started: `lumen init`

Scaffold a ready-to-edit project in the current directory (or a new one):

```sh
lumen init my-app
cd my-app
lumen compile main.ts && ./main
```

`lumen init` writes a starter `main.ts`, plus `lumen.d.ts` and `tsconfig.json`
so the project is editor- and `tsc`-clean from the first keystroke, you never
hand-write the ambient declarations. Existing files are never overwritten;
each is skipped with a notice.

## Imports

Import a default export from a relative file or straight from a URL:

```ts
import helpers from "./helpers.ts";
import greet from "https://lumen-lang.org/package/std-contrib/hello/hello.ts";

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
