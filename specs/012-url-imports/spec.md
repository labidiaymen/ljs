# Feature Specification: URL Imports

**Feature Branch**: `main` (milestone 012) | **Created**: 2026-06-28 |
**Status**: Draft

**Input**: Let a program import a module from a remote `https://` URL, so packages
can live anywhere (the decentralized model). The fetched `.ts` is inlined at
build time, exactly like a local relative import.

## Scope

- `import name from "https://host/path/x.ts";` fetches the URL at build time and
  makes its `export default function` available under `name`.
- HTTPS only (reject `http://`), URL must end in `.ts`.
- Nested imports inside a fetched remote file may be further `https://` URLs or
  relative paths (`./x.ts`, `../y/z.ts`). Relative paths are resolved against the
  remote file's URL and fetched recursively, so a multi-file package works.
- A package's inline `test` blocks are stripped when it is imported (they run
  only when that file is tested directly).
- In-build dedup and cycle detection keyed by URL.

Out of scope (future): on-disk caching, integrity hashing / lockfiles, named
imports, package-name resolution, a registry.

## User Scenarios

### Import a remote module (P1)

```ts
import greet from "https://raw.githubusercontent.com/lumen-lang-org/std-contrib/main/packages/hello/hello.ts";
console.log(greet("world"));
```

**Independent test**: compiling the entry file fetches the URL, inlines its
default function, and the binary runs.

## Requirements

- **FR-001**: An `import name from "https://…/x.ts"` MUST fetch the URL over
  HTTPS at build time and inline its module, mapping its `export default
  function` to `name`.
- **FR-002**: A non-`https` remote URL, or a URL not ending in `.ts`, MUST report
  `E_UNSUPPORTED_IMPORT`.
- **FR-003**: A fetch failure (network error or non-200 response) MUST report
  `E_IMPORT_NOT_FOUND`.
- **FR-004**: The same URL imported more than once in a build MUST be inlined
  once; an import cycle through URLs MUST report `E_IMPORT_CYCLE`.
- **FR-005**: A relative import (`./x.ts`, `../y/z.ts`) inside a fetched remote
  file MUST be resolved against that file's URL and fetched recursively.
- **FR-006**: Local relative imports continue to work unchanged.
- **FR-007**: A module's inline `test` blocks MUST NOT be emitted into a build
  that imports it; they run only when the file is tested directly.

## Diagnostics

Reuses `E_UNSUPPORTED_IMPORT`, `E_IMPORT_NOT_FOUND`, `E_IMPORT_CYCLE`,
`E_DUPLICATE_IMPORT`.

## Success Criteria

- **SC-001**: A program importing a default function from an `https://` `.ts`
  URL compiles and runs.
- **SC-002**: `http://` or non-`.ts` URLs fail with `E_UNSUPPORTED_IMPORT`.
- **SC-003**: An unreachable URL fails with `E_IMPORT_NOT_FOUND`.

## Security note

Remote imports execute fetched code at build time. V1 mitigations: HTTPS only.
A lockfile/integrity-hash mechanism is the next step before this is recommended
for untrusted sources.
