# URL imports

Import a module straight from a URL. The `.ts` is fetched over HTTPS at compile
time and inlined into the build. There is no package manager and no install
step -- a package is just a URL.

## Run

```sh
lumen compile remote.ts && ./remote
# Hello, world!

lumen compile recursive.ts && ./recursive
# Hey Lumen!!!
```

## How it works

- An import specifier may be a relative path (`./util.ts`) or an `https://` URL
  ending in `.ts`.
- A URL module is fetched and inlined exactly like a local file. Its
  `export default function` becomes the imported binding.
- A URL module may import its own siblings with relative paths; they are
  resolved against the module's URL and fetched recursively.
- The same URL is fetched once per build; import cycles are reported.

Only `https://` is allowed. Remote code runs at build time, so import from
sources you trust.
