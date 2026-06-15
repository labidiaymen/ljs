#!/usr/bin/env bash
# Code-quality gate for ljs (constitution v1.1.0). Always enforces `zig fmt`;
# additionally runs ZLint when it is installed. Invoked by `zig build lint`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> zig fmt --check"
zig fmt --check src build.zig

if command -v zlint >/dev/null 2>&1; then
  echo "==> zlint"
  zlint src
else
  echo "==> zlint not installed — skipping (optional). Install: https://github.com/DonIsaac/zlint"
  echo "    (zig fmt formatting was still enforced above.)"
fi

echo "lint: ok"
