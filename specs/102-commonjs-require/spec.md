# Spec 102 — CommonJS `require` + `module` + core-module registry (`path`, minimal `fs`/`os`) — Node axis, slice 5

Status: In progress
Owner: Aymen

## Goal
The minimum to **`require()` a simple npm library package**. Most npm libraries are CommonJS
(`require('pkg')` / `module.exports`); a pure-JS one (`ms`, `is-odd`, `leftpad`, `lodash`, …) needs
only `require` + module resolution + the engine (already at 95% language). This slice delivers that
keystone, plus `path` (used by resolution + common) and a minimal `fs` (the loader reads files anyway).

Host-only (CLI `ljs run`), like the rest of the Node axis. NOT on the Test262 path.

## CommonJS module system

### `require(specifier)` resolution (Node algorithm, minimal)
1. **Core module** → if `specifier` is a registered core module (`path`, `fs`, `os`, `util`, `events`,
   and `node:`-prefixed forms) return its (cached) exports.
2. **Relative / absolute** (`./`, `../`, `/`, drive-letter on Windows) → resolve against the requiring
   module's directory: try `X`, `X.js`, `X.json`, then `X/package.json`'s `main`, then `X/index.js`.
3. **Bare** (`pkg` or `pkg/sub`) → walk up from the requiring dir: `<dir>/node_modules/pkg` … resolved
   as a directory (package.json `main` → `index.js`), repeating up to the filesystem root.
4. `.js` → run as a CommonJS module; `.json` → `JSON.parse` the file → exports. Not found → throw a
   `Error` with `code: "MODULE_NOT_FOUND"`.

### Module execution (in-realm)
Wrap the source: `(function (exports, require, module, __filename, __dirname) { <source>\n})` — parse
+ run it **in the current interpreter/realm** (so it shares globals/Buffer/process/the module cache),
capture the resulting function, then call it with `(module.exports, requireFn, module, filename, dir)`.
`module = { exports: {}, id, filename, loaded:false }`; after the call, cache `module.exports` by
resolved path and return it (a circular require sees the partial `exports`). A parse error / a throw
propagates as a normal JS error.

### Per-module `require`
`require` is a native function object created **per module**, carrying that module's directory as a
hidden own property (e.g. `"%dir%"`) — the native dispatch reads the dir off the `func` object it's
called on (callNative receives `func`). `require.cache` and `require.resolve(x)` are minimal:
`resolve` returns the resolved absolute path; `require.main` may be undefined for now.

### Entry script (`ljs run file.js`)
Inject `require` (bound to the file's directory), `module`, `exports`, `__filename`, `__dirname` for
the top-level script so it can `require(...)`. (The entry stays script-scoped — not fully
module-wrapped — which is a minor deviation from Node but sufficient; required modules ARE wrapped.)

## Core modules (this slice)
- **`path`** — `join`, `resolve`, `dirname`, `basename`, `extname`, `normalize`, `isAbsolute`,
  `relative`, `parse`, `sep`, `delimiter`. (POSIX + Windows aware via `process.platform`.)
- **`fs`** (sync subset) — `readFileSync(path[,enc])` (returns a Buffer, or a string if enc given),
  `existsSync`, `writeFileSync`, `statSync` (minimal `{ isFile(), isDirectory(), size }`),
  `readdirSync`, `mkdirSync`. Backed by `self.io` / `std.Io.Dir`.
- **`os`** (minimal) — `platform()`, `arch()`, `type()`, `release()`, `EOL`, `homedir()`, `tmpdir()`,
  `hostname()`, `cpus()` (stub array), `totalmem()`/`freemem()` (stub), `endianness()`.
- **`util`** (minimal) — `format`, `inspect` (basic), `inherits`, `promisify`, `types` (a few),
  `isDeepStrictEqual` (optional). [stretch — include if cheap]
- **`events`** — a minimal `EventEmitter` (`on`/`addListener`/`once`/`emit`/`removeListener`/
  `removeAllListeners`/`listeners`/`listenerCount`), the default export = the class. [stretch]

`path` + `fs` are the required minimum; `os`/`util`/`events` are included as cheap wins where time
allows (defer to a follow-up otherwise).

## Acceptance
- A local `/tmp/pkg/index.js` with `module.exports = (n) => n*2;` and `/tmp/app.js` with
  `const f = require('./pkg'); console.log(f(21));` → `42` via `ljs run /tmp/app.js`.
- `require('./data.json')` returns the parsed object.
- `node_modules` resolution: `/tmp/proj/node_modules/leftpad/package.json` (`"main":"lib.js"`) +
  `lib.js` exporting a fn → `require('leftpad')` from `/tmp/proj/app.js` works.
- Circular require: `a` requires `b` requires `a` → no infinite loop; `a`'s partial exports seen.
- `const path = require('path'); path.join('a','b') === "a"+sep+"b"`, `path.extname("x.js")===".js"`.
- `const fs = require('fs'); fs.readFileSync(__filename, 'utf8')` returns the script source.
- `require('does-not-exist')` throws an Error with `code === "MODULE_NOT_FOUND"`.
- Bonus: drop a real tiny pure-JS package's source under node_modules and `require` it.
- **Regression:** all host-only — `language/` + `built-ins/` 0 regressions; build/test/lint/bench green.

## Out of scope (later)
- ESM host loader / `import` of npm packages, `package.json` `exports`/`imports` maps + conditions,
  `type:"module"`, `require(ESM)`. Full `fs` (async/promises/streams/watch), `fs.promises`. Full
  `util`/`os`/`events`. `__dirname` for the entry when run from stdin. Native addons. `require.main`.
