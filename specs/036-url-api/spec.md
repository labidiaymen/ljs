# Spec 036: url API

## Goal

A practical subset of Node's `url` module (the legacy `url.parse()` /
WHATWG-`URL`-object shape, not a `URL` class): `url.parse(str)` and
`url.format(parts)`. Picked as the next stdlib target for the same reason
`crypto` was: pure string parsing, no syscalls, works identically on the
native and WebAssembly targets. Lumen's own package-import mechanism already
parses URLs to fetch packages over HTTPS, so this isn't unfamiliar ground.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `url.parse(str)` | `string -> { protocol, hostname, port, pathname, search, hash, href }` | the second **record-returning builtin family** after `path.parse`, same pattern: a synthetic record type, all fields plain (non-optional) strings |
| `url.format(parts)` | `{ protocol, hostname, port, pathname, search, hash, href } -> string` | reconstructs a URL string from the record; round-trips with `parse` |

Field shape, matching the WHATWG `URL` object's naming and conventions
(`href`'s existence is the one deviation, added for round-tripping and
convenience, same reasoning as Node keeping it despite it being derivable
from the other fields):

- `protocol` includes the trailing colon (`"https:"`, not `"https"`).
- `hostname` excludes the port.
- `port` as a string, empty string if not explicit in the input.
- `pathname` starts with `/`, defaults to `"/"`.
- `search` includes the leading `?` if present, else empty string.
- `hash` includes the leading `#` if present, else empty string.
- `href` is the original input string, unmodified.

## Design notes

- **Parsing**: the runtime's URI type (used elsewhere for HTTP requests) does
  the real parsing work; this just walks its already-decoded component
  fields into the record shape above, allocating owned copies as needed
  (percent-decoding included, matching Node/WHATWG behavior).
- **No username/password/auth fields**: Node's `url.parse()` exposes `auth`;
  the WHATWG object has `username`/`password`. Left out of v1 as a niche
  case; the underlying parser still ignores/accepts them without erroring
  if present in the input, they're just not exposed as fields yet.
- **No query-string-to-object parsing**: `search` stays a raw string
  (`"?a=1&b=2"`), not decomposed into key/value pairs. Node's
  `querystring.parse`/`URLSearchParams` do this; deferred, since it either
  needs a growable-array/`Map`-construction path from generated code that
  doesn't exist yet for a stdlib builtin, or a fixed-shape return that's
  awkward for an unbounded number of query parameters.
- **Malformed input**: on a parse failure, every field falls back to an
  empty string except `pathname` (`"/"`) and `href` (the original input,
  always preserved verbatim) -- mirrors how `path.parse`/`fs.statSync`
  degrade to a zeroed/empty record rather than erroring, since Lumen has no
  exception path out of a stdlib function today.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `new URL(str)` as a real class / WHATWG `URL` object methods (`.searchParams`, `.toString()`) | Node's modern API is class-based; `url.parse`/`format` (the older, function-based API) fit Lumen's static-function stdlib pattern much better for v1 |
| `querystring.parse`/`stringify`, `URLSearchParams` | needs either a growable-array or `Map`-construction path from a stdlib builtin, neither of which exists yet |
| `username`/`password`/`auth` fields | niche; straightforward to add later without breaking the existing fields |
| URL resolution (`new URL(relative, base)`) | a real, separate feature (relative-to-absolute resolution against a base URL), not just parsing one string |
