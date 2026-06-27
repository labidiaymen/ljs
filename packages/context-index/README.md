# @lumen/context-index

Native context indexing experiment for AI-agent Node projects.

This package follows the same broad shape as native npm tools: a small Node.js
wrapper handles package ergonomics, while a Lumen-compiled native binary handles
the hot file scoring path.

## Build

```sh
npm run build:native
```

from `packages/context-index`, or:

```sh
node packages/context-index/scripts/build-native.js
```

from the repository root.

## Demo

```sh
node packages/context-index/bin/context-index.js build examples/context-index-demo
node packages/context-index/bin/context-index.js search examples/context-index-demo "repo search"
```

The first command writes `.lumen/context-index.json`. The second command loads
that index and calls the native Lumen scorer for each indexed file.

## V1 Scope

- Indexes `.ts`, `.js`, `.zig`, `.md`, and `.json` files.
- Ignores `.git`, `node_modules`, `dist`, `build`, `zig-cache`, `zig-out`, and
  `.lumen`.
- Extracts simple symbols from TypeScript/JavaScript-like files.
- Scores up to three query terms using the native Lumen binary.

This is intentionally not a vector index yet. It is the smallest useful step
toward repo navigation for AI agents.
