# Spec 103 — Node core modules, wave 1 (`events`, `util`, WHATWG `URL`/`TextEncoder`, `Buffer` expansion)

Status: In progress
Owner: Aymen

## Context
Slice 5 (spec 102) landed CommonJS `require` + `path`/`fs`/`os`, so pure-JS npm packages run. Wave 1
fills the next-most-required surface so MORE packages run — implemented as **4 independent units**
(parallel agents, distinct new files), all **host-only** (installed via `host_setup` / the
`host_require` core-module registry; NEVER on the Test262 path → 0 Test262 regressions by construction).

Each unit: a new `host_<x>.zig`, its own `NativeId`(s) + dispatch arm in `interp_native.zig`
(additive), and registration (a core module in `host_require`'s registry, or a global in
`host_setup`). Reuse the established patterns (per-instance native state via a hidden own prop read off
`func` in `callNative`; `Object.createNative`/`defineData`; `self.callFunction`).

## Unit A — `events` (EventEmitter) — `require('events')`
`EventEmitter` class (default export = the class; also `events.EventEmitter`). Methods: `on`/
`addListener`, `once`, `off`/`removeListener`, `removeAllListeners`, `emit(type, ...args)` (calls each
listener synchronously in add order, `this`=emitter; returns true iff there were listeners),
`listeners(type)`, `rawListeners`, `listenerCount(type)`, `eventNames()`, `prependListener`,
`prependOnceListener`, `setMaxListeners`/`getMaxListeners` (store value; no warning needed),
`emitter.emit('error', err)` with no listener → throw `err`. Per-instance listener storage on the
instance (a hidden own prop, or an own Map). `static EventEmitter.once(emitter, name)` may be deferred.
**Acceptance:** `const {EventEmitter}=require('events'); const e=new EventEmitter(); let got; e.on('x',(v)=>got=v); e.emit('x',42); // got===42`; `once` fires once; `removeListener` works; `listenerCount` correct; emitting `'error'` with no handler throws.

## Unit B — `util` — `require('util')`
`format(fmt, ...args)` (%s/%d/%i/%f/%j/%o/%O/%% + trailing args appended), `inspect(obj, opts?)`
(readable rendering of primitives/arrays/objects/functions, depth-limited; quotes strings inside
objects), `promisify(fn)` (returns a function returning a Promise; calls `fn(...args, (err,res)=>…)`),
`callbackify` (optional), `inherits(ctor, superCtor)` (set `ctor.super_ = superCtor` & prototype
chain), `deprecate(fn,msg)` (returns fn; warns once — may no-op the warning), `types` (a few:
`isDate`, `isRegExp`, `isNativeError`, `isPromise`, `isArrayBuffer`, `isTypedArray`),
`isDeepStrictEqual(a,b)` (optional), `inspect.custom` symbol (optional), `TextEncoder`/`TextDecoder`
re-export (optional — Unit C owns the globals).
**Acceptance:** `util.format('%s=%d','x',5)==='x=5'`; `util.inspect({a:1,b:[2,3]})` is a readable string; `util.promisify((cb)=>cb(null,7))().then(v=>…7)`; `util.inherits` links the prototype.

## Unit C — WHATWG globals: `URL` / `URLSearchParams` + `TextEncoder` / `TextDecoder`
Installed as GLOBALS (host_setup) AND requireable via `require('url')` (URL/URLSearchParams) /
`require('util')` already (skip — Unit B). New `host_url.zig`.
- `URL`: parse `new URL(input[, base])` → `href`/`protocol`/`host`/`hostname`/`port`/`pathname`/
  `search`/`searchParams`/`hash`/`origin`/`username`/`password`; `toString`/`toJSON`. A minimal but
  correct parser for http(s)/file/ws URLs (full WHATWG URL spec is large — cover the common shape:
  scheme://host[:port]/path?query#frag; throw `TypeError` on an invalid absolute URL with no base).
- `URLSearchParams`: `get`/`getAll`/`set`/`append`/`delete`/`has`/`forEach`/`toString`/`keys`/`values`/
  `entries`/`Symbol.iterator`; constructed from a string `"a=1&b=2"` or an object/array of pairs.
- `TextEncoder`: `encode(str)` → Uint8Array (UTF-8); `encoding === "utf-8"`. `TextDecoder`:
  `decode(uint8array)` → string (UTF-8; ignore the fancy options first cut).
**Acceptance:** `new URL('https://a.com:8/p?q=1#h').hostname==='a.com'` and `.searchParams.get('q')==='1'`; `new URLSearchParams('a=1&b=2').get('b')==='2'`; `new TextDecoder().decode(new TextEncoder().encode('hé'))==='hé'`.

## Unit D — `Buffer` expansion (extend `host_buffer.zig`)
Add to the existing Buffer: the FULL read/write numeric matrix (`readInt8`/`readUInt8`, `Int16`/`UInt16`
LE·BE, `Int32`/`UInt32` LE·BE, `readFloatLE`/`BE`, `readDoubleLE`/`BE`, + the `write*` mirrors, and
`*Offset`-less `readIntLE`/`readUIntLE(off,len)` optional); `indexOf`/`lastIndexOf`/`includes`,
`fill(value[,start[,end]])`, `copy(target[,tStart[,sStart[,sEnd]]])`, `compare`/`Buffer.compare`,
`swap16`/`swap32`. Keep `host_buffer.zig` under the 2000-line budget (split a `host_buffer_rw.zig` if
needed). **Acceptance:** `Buffer.from([1,2,3]).indexOf(2)===1`; `Buffer.alloc(4).fill(7)[0]===7`; a Buffer copied into another; `readFloatLE`/`writeFloatLE` round-trip; `Buffer.compare(a,b)`.

## Cross-cutting acceptance / gate
- Each unit verified with hand-written `ljs run` scripts (above).
- All host-only → `language/` + `built-ins/` **0 regressions**; build/test/lint/bench green.
- Integration: distinct new files; the only shared edits are additive (NativeId enum, `interp_native`
  dispatch, the `host_require` core-module registry, `host_setup` globals) — merged sequentially.

## Out of scope (later waves)
- `stream` (depends on events; big), `fs.promises`/async fs, `crypto`, `net`/`http` (libxev I/O slice),
  `assert`/`querystring`/`string_decoder` (cheap — a later small wave), full WHATWG URL edge cases,
  `util.inspect` colors/options, EventEmitter `captureRejections`/async-iterator `events.on`.
