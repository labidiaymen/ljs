# tjs — work so far + the road ahead

A session-spanning record of two experiments and the direction we're committing to.

---

## Context: where this came from
The base project is **ljs** — a from-scratch JavaScript engine in Zig (~95% Test262, a tree-walking
interpreter). The honest conclusion about ljs: it's an impressive *engine*, but as a **product** it's
dominated — it hand-rebuilds what mature engines (quickjs/V8/JSC) already perfected. So the session
explored two ways to build something *useful* on top of that foundation.

---

## Track 1 — qjs: a Node-compatible runtime over quickjs-ng  (branch `quickjs-runtime`)
**Idea:** stop hand-writing the engine; embed **quickjs-ng** (a real, conformant engine) and build only
the host layer in Zig — the txiki.js / Bun pattern.

**Built:**
- quickjs-ng compiled by Zig's C compiler (no CMake), `@cImport` + a tiny value-macro shim.
- A **libxev event loop + native HTTP server**; per-request dispatch into JS.
- A Node-compat layer in JS (`bootstrap.js`): `require` (CommonJS + node_modules), `http` req/res,
  `EventEmitter`, `util`, `Buffer`, `stream`, `path`, `url`, `querystring`, plus loadable stubs.
- **Runs the real npm `express` package** — full dependency tree, GET + POST/JSON CRUD APIs.

**Measured (Windows loopback, Express Hello-World):**
- Throughput: bun 14k req/s · **qjs 8.7k** · node 7.0k  (qjs beats Node; ~62% of Bun — the JIT gap).
- RAM under load: **qjs 10.6 MB** vs node 118 MB vs bun 172 MB → **~11–16× leaner**.
- Per-RAM: ~8 qjs instances fit in one Bun's RAM → **~4× the aggregate throughput per MB**.

**Verdict:** a strong *technical* result, but **not a standalone product** — runtimes are weak products
(adoption is brutal, no moat; even Bun/Deno monetize a platform, not the runtime). Kept as a credential
and a component. Not the path forward.

---

## Track 2 — tjs: Typed-JS → Zig → native compiler  (branch `tjs-native`)  ← THE DIRECTION
**Idea:** a statically-typed, JS-like language that compiles to a **native binary** — by lowering to
**Zig source** and letting `zig build-exe` (LLVM) do codegen. We write only the front-end + lowering;
optimization, native codegen, cross-compilation, and the whole Zig/C ecosystem come **free**.

`app.tjs ──tjsc──▶ app.zig ──zig build-exe──▶ app.exe` (literally; the `.zig` is a real file on disk).

**Built this session (spec 142):**
- `ljs compile <file>` — typed-JS → native binary.
- Typed `const`/`let`(immutable) and `var`(mutable): `int`/`i64`, `number`/`f64`, `bool`, `string`.
- Arithmetic (`+ - * / %`), comparisons (`< > <= >= == !=`), `while` loops, assignment.
- **Typed objects**: `type T = {…}` → a flat Zig **struct**; object literals + field access.
- `console.log`.
- **Compile-time errors located in `.tjs`** (syntax + undefined variables) — Rust/TS-style caret.
- **Runtime errors mapped to `.tjs`** — `file:line:col` + the source line + a caret (custom panic
  handler + embedded source; Zig has no `#line`, so we do the mapping ourselves).
- **Rides the Zig ecosystem**: `httpGet(url)` (real HTTPS via `std.http`, TLS and all) and
  `serve(port, body)` (a native HTTP server via `std.Io.net`).

**Measured:**
- Compute (300M-iter loop): **tie with Node** (V8 JITs hot loops to the same `idiv`; AOT doesn't win
  on pure compute).
- **Startup ~2× faster**, **803 KB self-contained binary** (no runtime), tiny RAM.

**Why this is the right project:** *bounded, finishable* scope you control — vs the Node alternative's
*unbounded* compatibility tail (you're never done). And it sidesteps the "new language has no
libraries" death by riding Zig std + the entire C ecosystem + free cross-compile.

---

## Key truths established (so we don't relitigate them)
- **Dynamic JS can't compile to clean native** (it needs a runtime/GC). **Typed JS can** — the types are
  the bridge. So this is "native TypeScript," not "native JavaScript."
- **TypeScript maps to Zig far better than JS** — Zig needs static types; TS provides them.
- Dropping dynamic **doesn't win on compute** (V8's JIT matches native there). It wins on **startup,
  memory, binary size, and compile-time safety**. That's the honest value prop.
- Support the **~95% of TS that describes data** (interfaces, generics, unions, enums, `Omit`/`Pick`/
  `Partial` via comptime) — **drop the ~5% type-level computation** (`infer`, conditional/template
  types). This is the same subset AssemblyScript / Static Hermes target.
- Transpile-to-a-lower-language is **proven long-term** (C++→C historically; Nim/Vala→C today), not a
  hack. The technique has a future; *adoption* is the unsolved axis for any new language.
- These are **craft / portfolio** projects done clear-eyed — not product bets. tjs is chosen because
  it's the most *doable and finishable*.

---

## The road ahead (tjs)

### Foundation refactor — proper AST + type checker  (~4 cycles)
The current parser is single-pass "parse-and-emit" with string types — great for a POC, too minimal for
real TS typing. Evolve to the standard pipeline `parse → AST → type-check → emit`:
1. **Statement AST + separated codegen** (the structural move; biggest cycle).
2. **Type AST + symbol table** (replace string types; track struct field types).
3. **Type checker** — inference + checks (mismatch, coercion, operators) with located diagnostics.
4. **Typed codegen + cleanup** — type-correct formatting/arithmetic; remove inline emit.

### Then, building on the typed AST
- **Functions** — unlocks real per-request HTTP handlers, methods, and multi-frame stack traces.
- **Classes** → Zig structs + methods (`constructor`→`init`, `this`→`self`, `new`→`T.init`).
- **More stdlib builtins** riding Zig std — `readFile`, `now`, `sha256`, TCP, etc. (wrappers bridge the
  type gap: tjs sees clean types, Zig-isms hidden).
- **TS utility types** — `Omit`/`Pick`/`Partial`/`Record` via Zig comptime metaprogramming.
- **Modules** — ESM `import`/`export` between `.tjs` files → Zig `@import` (single-compile, no plumbing).
- **Package manager** — a tjs manifest → generated `build.zig`/`build.zig.zon` so tjs uses real Zig
  packages + C libraries.

### Positioning
**"Native TypeScript" — write typed JS, compile to a tiny self-contained native binary, ride the Zig +
C ecosystem.** A finishable language for native CLIs / tools / small servers / edge — where instant
startup, low memory, and a single static binary matter, and npm isn't the point.
