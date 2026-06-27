# Tasks: URL Imports

- [x] T1 `parseImportSpec`: accept `https://…/x.ts`; reject `http://` and
  non-`.ts` URLs with the unsupported-import path.
- [x] T2 Add `fetchUrl(arena, io, url)`: HTTPS GET via `std.http.Client` with a
  `response_writer`; non-200 → error.
- [x] T3 `appendExpandedSource`: branch URL vs local — fetch URL bodies, key
  dedup/cycle by URL, resolve relative imports inside a remote file against its
  URL base (`joinUrl`) and fetch them recursively.
- [x] T4 Strip `test` blocks from imported modules (depth > 0) so a package's
  inline tests do not leak into a consumer build.
- [x] T5 Verify: remote import compiles+runs (hello), recursive URL-relative
  import compiles+runs (greeter); `http://` / non-`.ts` / unreachable host
  produce the right diagnostics; `zig build conformance` green.
