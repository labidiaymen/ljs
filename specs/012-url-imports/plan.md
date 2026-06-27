# Implementation Plan: URL Imports

**Branch**: `main` | **Spec**: [spec.md](./spec.md)

## Summary

Imports are resolved by the CLI (`src/lumen.zig`) as a build-time textual
inlining pass (`readSourceWithImports` → `appendExpandedSource`). URL imports
extend that pass: when an import specifier is an `https://…/.ts` URL, fetch it
with `std.http.Client` and inline the body exactly like a local file. The
compiler core is unchanged.

## Affected code

- `src/lumen.zig`
  - `parseImportSpec` — accept `https://` specifiers (require `.ts`); keep
    rejecting `http://`, bare, and named imports.
  - new `fetchUrl(arena, io, url) ![]const u8` — HTTPS GET via
    `std.http.Client` with `response_writer` capturing the body
    (`std.Io.Writer.Allocating`); non-200 → error.
  - `appendExpandedSource` — branch on URL vs local: for a URL, fetch the body
    and use the URL as the dedup/cycle key; for a local file inside a remote
    file, error. Reuse the existing `visiting`/`emitted` maps and default-export
    rewriting.

## Approach

1. Detect URL specifiers (`std.mem.startsWith(spec, "https://")`).
2. `parseImportSpec` returns the URL as the spec; `http://` or non-`.ts` → error.
3. In `appendExpandedSource`, add an `is_remote` notion: the "path" may be a URL.
   - Source bytes: URL → `fetchUrl`; else → `readFileAlloc`.
   - Dedup/cycle key: URL → the URL string; else → the resolved local path.
   - Child import base: a remote file can only import other `https://` URLs;
     a `./`/`../` import inside a remote file errors.
4. `fetchUrl`: build `std.http.Client{ .allocator, .io }`, `ca_bundle.rescan`,
   `client.fetch(.{ .location = .{ .url }, .response_writer = &aw.writer })`,
   check status == 200, return the accumulated bytes.

## Verification

- A fixture entry that imports a known-good `https://` `.ts` URL compiles and
  runs (network-dependent; run manually / in CI, not in the offline conformance
  suite).
- Negative cases (`http://`, non-`.ts`, unreachable host) checked via `lumen
  compile` diagnostics.
- `zig build conformance` stays green (local imports unaffected).

## Risks

- HTTP client / TLS (`ca_bundle`) availability on the host.
- Network flakiness — keep remote cases out of the offline conformance gate.
- Security: build-time remote code execution (HTTPS-only for now).
