# qjs — Zig runtime over quickjs-ng (the "embed a proven engine" track)

A second runtime track for the project: instead of the hand-written ljs engine (byte-strings +
tree-walk interpreter), this embeds **quickjs-ng** — the actively-maintained QuickJS fork — as the
JavaScript engine, and builds the host/runtime layer in Zig on top. Same idea as **txiki.js**
(QuickJS + libuv) and **Bun** (JavaScriptCore + Zig): let a real, conformant engine handle the
*language*, and spend our effort on the *runtime* (Node-compat APIs, event loop, bundler glue).

## Why this track exists
The hand-written ljs engine is ~95% Test262 but pays for it: byte-oriented strings + a tree-walk
interpreter mean (a) recurring language edge-cases (nested templates, regex-in-interpolation,
`\p{…}` Unicode property escapes — each a debugging cycle) and (b) slower execution. quickjs-ng gives
all of that for free: a full bytecode VM, UTF-16 strings, ~100% Test262. The first build already runs
JS that took the hand-written engine multiple fixes:

```
quickjs result: {"wrap":"[<ok>]","ident":true,"esc":"a"}
   nested template ^            \p{L} regex ^       regex-in-interp ^
```

## Layout
- `vendor/quickjs-ng/` — the engine C sources (gitignored; fetched by `./fetch.sh`).
- `build.zig` — compiles the 4 core C files (`quickjs.c` `libregexp.c` `libunicode.c` `dtoa.c`)
  with Zig's C compiler and links them into a Zig exe. `linkLibC`.
- `src/main.zig` — the embed entry. Today: proof-of-life eval. Next: the host API surface.

## Build
```sh
cd qjs
./fetch.sh          # clone quickjs-ng into vendor/ (once)
zig build run       # compile engine + run the demo
```

## Roadmap (host layer — the actual work)
The engine is done (it's quickjs-ng). The work is the Zig host layer against `JSContext`:
1. A REPL / `qjs run <file>.js` entry (read file → `JS_Eval` → drain job queue).
2. The event loop (reuse the project's **libxev**) + `setTimeout`/microtask pump.
3. Node-compat modules — reuse the *design* from the ljs host modules (`fs`/`http`/`https`/`stream`/
   `events`/`buffer`/`process`), rewritten against QuickJS's `JSValue` C API instead of ljs's `Value`.
   Engine-agnostic data (unicode tables, `constants`, mime types, path/querystring algorithms) can be
   shared with ljs via a future `shared/` module.
4. CommonJS `require` + the ESM loader on top of `JS_Eval` (QuickJS has native ESM).

## Relationship to ljs
Sibling tracks, not a replacement. `ljs` (root) = the from-scratch engine (conformance/craft).
`qjs/` = the practical runtime (runs real code). Overlap (engine-agnostic logic) is shared; the
engine + bindings differ. See the root project notes for the dual-track rationale.
