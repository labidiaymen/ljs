# Standard Library Roadmap (draft)

**Status**: Draft / design only — not yet implemented.

## Goal

Grow the Lumen standard library with a **familiar, conventional API surface**
(the same names and shapes JS/TS developers already know — `fs.readFileSync`,
`path.join`, `process.argv`, `JSON.stringify`, `arr.map`), but implemented on top
of **Zig's standard library** and the Lumen static type system.

Principles:

- **Familiar names, native semantics.** Mirror the well-known API *shapes* for
  ergonomics; the implementation is Zig, statically typed, no dynamism.
- **Synchronous-first.** Blocking calls (`*Sync` style) until the async runtime
  lands; async variants come with the event loop (libuv).
- **Explicit, per-API wrappers.** Each member is contracted, type-checked, and
  arity-checked before lowering — never a whole runtime inherited wholesale.
- **No surface branding.** Public docs describe the Lumen library, not any other
  runtime.

### Status legend

- **shipped** — already in V1
- **ready** — implementable now with current language features
- **needs: X** — blocked on a language capability (see Prerequisites)

## Prerequisites (cross-cutting language work)

Several modules depend on language features not yet built:

| Capability | Unlocks |
|---|---|
| **Mutable / dynamic arrays** (`ArrayList`-backed, `push`/`pop`) | `Array` mutation, `readdir`, `split`, `JSON` arrays |
| **Generics** (monomorphized) | typed containers (`Map`, `Set`), generic `Array<T>` helpers |
| **Closures** (shipped) | `Array.map/filter/reduce/forEach`, sort comparators |
| **Tagged unions / `any`-like value** | `JSON.parse` result, heterogeneous data |
| **Async runtime (libuv)** | async `fs`, `net`, `http`, timers, Promises |
| **String builder / owned strings** | most `String` and formatting methods (they allocate) |

## Modules

### console — *shipped / extend*

| API | Zig backing | Status |
|---|---|---|
| `console.log(x)` / `console.error(x)` | `std.debug.print` / stderr | shipped |
| `console.warn(x)` / `console.info(x)` | `std.debug.print` | ready |
| `console.assert(cond, msg)` | conditional print | ready |

### Math — *shipped / extend*

| API | Zig backing | Status |
|---|---|---|
| `abs, max, min, sign, clamp, sqrt` | `@abs/@sqrt/std.math` | shipped |
| `floor, ceil, round, trunc` | `@floor/@ceil/@round/@trunc` | ready |
| `pow, log, log2, log10, exp` | `std.math.pow/log/...` | ready |
| `sin, cos, tan, atan2, hypot` | `std.math` | ready |
| `PI, E` constants | `std.math.pi/e` | ready |
| `random()` / `randomInt(n)` | `std.Random` (seeded) | ready |

### fs — *partial*

| API | Zig backing | Status |
|---|---|---|
| `fs.readFileSync(path, encoding?)` | `Dir.readFileAlloc` | shipped |
| `fs.writeFileSync(path, data)` | `Dir.writeFile` | ready |
| `fs.appendFileSync(path, data)` | open + seekEnd + write | ready |
| `fs.existsSync(path)` | `Dir.access` | ready |
| `fs.mkdirSync(path, recursive?)` | `Dir.makeDir` / `makePath` | ready |
| `fs.rmSync(path) / unlinkSync` | `Dir.deleteFile` / `deleteTree` | ready |
| `fs.renameSync(a, b)` | `Dir.rename` | ready |
| `fs.copyFileSync(a, b)` | `Dir.copyFile` | ready |
| `fs.statSync(path)` → `{ size, isFile, isDirectory, mtime }` | `Dir.statFile` | needs: record return + bool fields (have records) |
| `fs.readdirSync(path)` → `string[]` | `Dir.iterate` | needs: dynamic arrays |
| async `fs.readFile`/`writeFile` (Promise) | libuv | needs: async runtime |

### path — *new, ready*

| API | Zig backing | Status |
|---|---|---|
| `path.join(...parts)` | `std.fs.path.join` | needs: rest/variadic (or fixed-arity v1) |
| `path.basename(p)` | `std.fs.path.basename` | ready |
| `path.dirname(p)` | `std.fs.path.dirname` | ready |
| `path.extname(p)` | `std.fs.path.extension` | ready |
| `path.resolve(...)` | `std.fs.path.resolve` | needs: variadic |
| `path.isAbsolute(p)` | `std.fs.path.isAbsolute` | ready |
| `path.sep` | `std.fs.path.sep` | ready |

### process — *partial*

| API | Zig backing | Status |
|---|---|---|
| `argsCount()` / `arg(i)` | runtime args | shipped |
| `process.argv` → `string[]` | runtime args | needs: dynamic/typed array surface |
| `process.cwd()` | `Dir.realpath(".")` | ready |
| `process.exit(code)` | `std.process.exit` | ready |
| `process.env(key)` → `string \| null` | process environment | ready (env API per platform) |
| `process.platform` / `process.arch` | `@import("builtin")` | ready (compile-time constants) |

### os — *new, ready*

| API | Zig backing | Status |
|---|---|---|
| `os.platform()` / `os.arch()` | `builtin.os.tag` / `builtin.cpu.arch` | ready |
| `os.tmpdir()` | env / platform default | ready |
| `os.homedir()` | environment | ready |
| `os.cpus()` (count) | `std.Thread.getCpuCount` | ready |
| `os.hostname()` | `std.posix`/platform | ready |

### String — *partial / extend*

| API | Zig backing | Status |
|---|---|---|
| `.length`, `s + t`, `String.isEmpty/contains/startsWith` | `std.mem` | shipped |
| `endsWith, indexOf, slice, substring, repeat` | `std.mem` | ready |
| `toUpperCase, toLowerCase, trim` | `std.ascii` (+ alloc) | ready |
| `split(sep)` → `string[]` | `std.mem.splitScalar` | needs: dynamic arrays |
| `replace, replaceAll` | `std.mem.replace` (+ alloc) | ready |
| `charCodeAt, padStart, padEnd` | `std.fmt`/`std.mem` | ready |

### Array — *partial / extend*

| API | Zig backing | Status |
|---|---|---|
| indexing, `.length`, `Array.isEmpty` | slices | shipped |
| `map, filter, reduce, forEach` | closures + alloc | ready (closures shipped) |
| `includes, indexOf, join` | `std.mem` | ready |
| `slice, concat` | alloc | ready |
| `push, pop, shift, unshift` | `ArrayList` | needs: mutable/dynamic arrays |
| `sort(cmp), reverse` | `std.sort` + closure | needs: mutable arrays |

### JSON — *new*

| API | Zig backing | Status |
|---|---|---|
| `JSON.stringify(value)` | walk typed value → text | needs: reflection over records (or per-type codegen) |
| `JSON.parse(text)` → typed | `std.json` | needs: tagged-union/`any` result type |

JSON is the hardest fit: parsing yields dynamic shapes, which clash with static
typing. Likely V1 form: `JSON.parse<T>(text): T` (typed, generic) once generics
land, plus `JSON.stringify` for records.

### time / Date — *new, ready*

| API | Zig backing | Status |
|---|---|---|
| `now()` (ms) | `std.time.milliTimestamp` | ready |
| `monotonic()` | `std.time.Instant` | ready |
| `Date` (basic fields) | `std.time.epoch` | needs: records + helpers |

### crypto — *new, ready*

| API | Zig backing | Status |
|---|---|---|
| `crypto.sha256(data)` / `sha1` / `md5` | `std.crypto.hash` | ready (returns hex string) |
| `crypto.randomBytes(n)` | `std.crypto.random` | needs: byte-buffer type |

### http / net — *partial*

| API | Zig backing | Status |
|---|---|---|
| `httpGet(url)` / `serve(port, body)` | `std.http` | shipped (builtins) |
| `http.get(url)` → `{ status, body }` | `std.http.Client` | needs: record return |
| async `fetch` / streaming server | `std.http` + libuv | needs: async runtime |

### assert — *new, ready*

| API | Zig backing | Status |
|---|---|---|
| `assert(cond)` / `expect(cond)` (tests) | `std.testing`/panic | `expect` shipped; `assert` ready |

## Suggested implementation order

1. **Pure, ready wins (no new language features):** extend `Math`, `path`,
   `os`, `process` (cwd/exit/env/platform), `crypto` hashes, `time.now`,
   `console.warn/info` — all map directly to Zig std.
2. **Closure-powered:** `Array.map/filter/reduce/forEach`, `String` transforms
   that allocate (`toUpperCase`, `trim`, `replace`).
3. **fs expansion:** `writeFileSync`, `existsSync`, `mkdirSync`, `statSync`
   (record return), `copyFileSync`, `rename`, `rm`.
4. **After dynamic arrays:** `readdirSync`, `String.split`, `Array.push/sort`,
   `process.argv`.
5. **After generics:** typed containers (`Map`/`Set`), `JSON.parse<T>`.
6. **After async runtime:** async `fs`/`http`/timers, Promises.

Each module ships as its own conformance-backed spec slice, mirroring the
existing milestone cadence.
