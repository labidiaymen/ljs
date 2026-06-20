#!/usr/bin/env bash
# Code-quality gate for ljs (constitution v1.1.0). Always enforces `zig fmt`;
# additionally runs ZLint when it is installed. Invoked by `zig build lint`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> zig fmt --check"
zig fmt --check src build.zig

if command -v zlint >/dev/null 2>&1; then
  echo "==> zlint --deny-warnings (src/*.zig via stdin)"
  # Feed zlint the explicit src .zig file list via stdin. zlint does NOT honour .gitignore for .zig
  # files, so a no-path walk from the repo root would also lint fetched dependency sources (e.g.
  # zig-pkg/libxev, spec 107) and fail on THEIR style; a bare dir arg (`zlint src`) lints 0 files.
  # `build.zig` is covered by the `zig fmt --check` above. --deny-warnings makes warnings fail.
  find src -name '*.zig' | zlint -S --deny-warnings
else
  echo "==> zlint not installed — skipping (optional). Install: https://github.com/DonIsaac/zlint"
  echo "    (zig fmt formatting was still enforced above.)"
fi

echo "lint: ok"
