# Tasks — Spec 120 Express enablement

- [x] `zlib` module (host_zlib.zig) + wiring → unblock `Cannot find module 'zlib'`
- [x] `require('stream')` returns the `Stream` constructor with classes attached → `util.inherits` works
- [x] Uncaught errors print V8 stack trace (hostReportError + runHost + thrown_reported)
- [x] Per-module source threading (CJS wrapper stamps script_source/name) → traces point into each file
- [x] Express LOADS (4.22.2); `express()` builds an app with `.get`
- [x] Gate: test + lint + bench + Test262 language differential (0 regressions)
- [ ] Fix `Router.prototype.route` null-deref (this.stack / route.dispatch) — Express serves a request
- [ ] (refinement) mid-expression engine-throw positions for exact throw lines
- [ ] real flate codec for zlib (gzip)
