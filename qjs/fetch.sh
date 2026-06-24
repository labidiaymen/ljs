#!/usr/bin/env bash
# Fetch the quickjs-ng engine sources into qjs/vendor/quickjs-ng (gitignored).
# quickjs-ng is the actively-maintained QuickJS fork (Test262-tracking, ES2023+).
set -euo pipefail
cd "$(dirname "$0")"
if [ -d vendor/quickjs-ng/.git ]; then
  echo "quickjs-ng already present; pulling latest"
  git -C vendor/quickjs-ng pull --ff-only
else
  mkdir -p vendor
  git clone --depth 1 https://github.com/quickjs-ng/quickjs.git vendor/quickjs-ng
fi
echo "quickjs-ng ready. Build: cd qjs && zig build run"
