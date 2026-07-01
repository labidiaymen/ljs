# Tasks: url API

## Phase 1

- [x] T1 Added `"url"` to the parser's `isStdNamespace` list. New
  `urlCallType` in `lumen_check_stdlib.zig`, wired into `staticCallType`.
- [x] T2 `registerLumenUrlParts` -- synthetic 7-field record type (protocol,
  hostname, port, pathname, search, hash, href), following
  `registerLumenPathParts`'s exact pattern.
- [x] T3 `url.parse(str)` -- `string -> __LumenUrlParts`, via the runtime's
  own URI parser (the same one used elsewhere for HTTP requests).
- [x] T4 `url.format(parts)` -- `__LumenUrlParts -> string`, via
  `ensureAssignable` like `path.format`.
- [x] T5 Verified: parsed a URL with port, query, and hash all combined --
  every field matched exactly (`protocol: "https:"`, `hostname:
  "example.com"`, `port: "8080"`, `pathname: "/foo/bar"`, `search:
  "?a=1&b=2"`, `hash: "#section"`, `href` preserved verbatim). Confirmed
  defaults on a bare `https://example.com` (empty port/search/hash,
  pathname `"/"`). `url.format(url.parse(u)) == u` round-tripped exactly.
  Confirmed the malformed-input fallback (`"not a valid url"` -> empty
  protocol, `pathname: "/"`, `href` preserved verbatim).
- [x] T6 Confirmed `--wasm` both compiles AND runs correctly (wasmtime,
  same verification standard as `crypto`) -- identical output to the
  native run for every case above.
- [x] T7 `zig build test` passes. `zig build conformance` run clean (no
  concurrent builds, same pre-existing failures, no new ones).
- [x] T8 Updated `website/stdlib.html`: new `url` quick-jump list + per
  function blocks; updated Planned table; added to the docs-nav sidebar.
- [x] T9 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: a real `URL` class with
`.searchParams`/methods, `querystring.parse`/`URLSearchParams` (needs a
growable-array or `Map`-construction path from a builtin), `username`/
`password`/`auth` fields, and relative-to-base URL resolution.
