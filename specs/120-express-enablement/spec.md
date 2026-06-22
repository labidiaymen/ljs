# Spec 120 — Express enablement: `zlib`, `stream`-as-constructor, uncaught stack traces, per-module source

**Status:** Done (2026-06-22). **Express 4.22.2 LOADS AND SERVES** on ljs — `app.get('/')` returns 200
text, `res.json()` returns 200 JSON with `content-type: application/json; charset=utf-8`. The keystone
was a real ECMAScript conformance bug (function-declaration re-instantiation), whose fix also gained
**+4 Test262** (language 42319 / 95.2%, 0 regressions).

## The keystone — function-declaration identity (§14.1.21)
Reaching a `function f(){}` statement RE-INSTANTIATED the function (a fresh object), so a reference
captured before its line saw a different object: `var a = R; function R(){}` gave `a !== R`. Express's
`route.js` does `module.exports = Route; … Route.prototype.dispatch = …`, so the exported `Route`'s
prototype never got the methods → `route.dispatch.bind` threw. Fix (interp_stmt): at a VAR scope the
hoist already bound the single object → the statement is a NO-OP (preserve identity); only a BLOCK/loop
body re-instantiates (fresh per-entry closure). +4 Test262, 0 regressions.

## What this cycle did (empirical blocker-by-blocker, driving real Express)
1. **`zlib` module** (`host_zlib.zig`, new): `body-parser` + `destroy` require it at load. Provides the
   factory functions (`createGunzip`/…) returning `stream.PassThrough`, the stream classes
   (`Gzip`/`Gunzip`/… for `instanceof`), `constants`, and `*Sync`/async stubs (real flate codec is a
   follow-up — only fires on gzipped bodies). Unblocked `Cannot find module 'zlib'`.
2. **`require('stream')` is the `Stream` constructor** (host_stream.zig): Node's stream module IS the
   legacy `Stream` base class (a function with a `.prototype`) carrying `Readable`/`Writable`/`Duplex`/
   `Transform`/`PassThrough`/`Stream` as properties — so `util.inherits(SendStream, require('stream'))`
   (in `send`) works. Was a plain object → `superCtor.prototype undefined`.
3. **Uncaught errors print their V8 stack trace** (host_timers `hostReportError`, engine `runHost`):
   like Node. New `error_stack.buildStringOnly` (the string even when `prepareStackTrace` is set — which
   depd does). New `EvaluationResult.thrown_reported` so a host-run top-level throw prints the trace once
   (no double "Uncaught" one-liner from `main`).
4. **Per-module source threading** (host_require): the CJS wrapper call stamps `script_source`/
   `script_name` to THIS module, so a stack frame for an Express-internal function maps to its own file
   (`node_modules/express/lib/router/index.js:…`) — not the entry script. This is what makes package
   debugging tractable.

## Result
`require('express')` → `express()` builds an app with `.get`. `app.get('/', h)` throws a TypeError
(`Cannot read properties of null or undefined`) inside `Router.prototype.route` — isolated via the new
per-module traces to `application.js:499` (`this._router.route(path)`).

## Next
- Pinpoint + fix the `Router.prototype.route` null-deref (`this.stack`/`route.dispatch`). The
  mid-expression engine-throw position refinement (spec 119 out-of-scope item) would land the exact line.
- Real flate codec for `zlib` (gzip responses / gzipped request bodies).
