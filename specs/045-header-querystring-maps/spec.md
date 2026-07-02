# Spec 045: header/querystring support via Map

## Goal

Close two items deferred across two already-shipped specs, both blamed on
the same "needs a header-collection type" gap: `url`'s querystring
(`?a=1&b=2` -> key/value pairs) and `http`'s custom request/response
headers. Both close by reusing `Map<K, V>` (spec 020), not a new type.

## The assumption behind the original deferral, checked, not just repeated

Both `url.parse`'s and `http.request`'s specs deferred this on "no
growable-array or `Map`-construction path from inside a stdlib builtin."
That was never actually tested -- verified now with a standalone program:
a plain Zig function *can* construct a `LumenMap(K, V)` internally
(`LumenMap([]const u8, []const u8).__init()`, then `.set(key, value)` in a
loop) and hand back a populated, real `Map<string, string>`. The
generated `LumenMap` type from spec 020 works exactly the same way
whether it's built from user-written Lumen code or from a runtime
helper's generated Zig -- there was no actual blocker, just an untested
assumption. This spec exists because that assumption turned out to be
wrong, not because a new capability was built.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `url.parse(str)`'s `query` field | `Map<string, string>` | new field on the existing `__LumenUrlParts` record, alongside `search` (which stays the raw `"?a=1&b=2"` string) |
| `http.request(url, method, body, headers)` | adds a 4th arg, `Map<string, string>` | request headers sent with the request |
| `http.get`/`createServer`'s response | `HttpResponse` gains a `headers: Map<string, string>` field | response headers, populated from the real response on the client side, from the handler's chosen headers on the server side |

**Client-side response headers are the one piece of this that's a real
implementation lift, not a quick field addition**: checked directly (not
assumed) that they're reachable at all -- `std.http.Client`'s lower-level
`Head`/`Response` type has `iterateHeaders()`, confirmed to exist by
reading the source -- but getting them means restructuring `__httpRequest`
away from `client.fetch()`'s one-shot convenience wrapper (which only ever
surfaces `status`) to the lower-level `client.request(...)` + wait +
manual header iteration flow underneath it. Everything else in this spec
(request headers via `extra_headers`, which `FetchOptions` already
supports directly; all of the server side, which already does its own
manual parsing/writing) is a straightforward extension of already-working
code.

## Design notes

- **`query` is additive, not a replacement for `search`**: `search` (the
  raw string) stays exactly as it is -- some callers want the raw string
  (e.g. to pass straight through when proxying), others want it parsed.
  Both are now available on the same record instead of forcing a choice.
- **Duplicate query/header keys**: `Map.set` overwrites on a repeated key
  (last one wins), the same behavior `LumenMap` already has for any
  duplicate `.set()` call. Node's real `URLSearchParams`/headers can
  represent repeated keys as an array of values; that's not carried over
  here, a deliberate simplification given `Map<string, string>` is what's
  actually available, not `Map<string, string[]>`.
- **`http.request`'s signature grows to 4 args** rather than an options
  record: matches the existing positional-argument shape
  (`url, method, body`) already shipped; an options-record redesign is a
  bigger API-shape change than this spec's scope, and could still happen
  later without conflicting with this addition (the 4th positional arg
  slots in cleanly either way).
- **Header name case**: HTTP header names are case-insensitive by spec,
  but `Map<string,string>`'s lookup is exact-match. Not normalized here --
  a real, documented gap, not an oversight; case-insensitive lookup would
  need either a custom-comparison variant of `Map` (doesn't exist) or
  normalizing every key to lowercase (a simpler follow-up if this proves
  to matter).

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Case-insensitive header lookup | `Map`'s exact-match lookup, or normalize every key to lowercase as a follow-up |
| Repeated header/query keys as an array of values | needs `Map<string, string[]>`; `Map<string, string>`'s last-write-wins is what's available now |
| An options-record form of `http.request` (replacing the positional args) | a bigger API-shape change, independent of this spec's scope |
