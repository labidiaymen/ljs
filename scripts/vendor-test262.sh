#!/usr/bin/env bash
# Vendor the official Test262 suite into vendor/test262 (gitignored), recording the exact
# commit in vendor/test262/.pinned-commit (constitution: Test262 vendored at a pinned commit).
#
# Usage:
#   scripts/vendor-test262.sh                                   # full clone (large)
#   scripts/vendor-test262.sh test/language/expressions/addition  # sparse subset (fast)
#   TEST262_COMMIT=<sha> scripts/vendor-test262.sh [<paths>...]  # pin a specific commit
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="https://github.com/tc39/test262.git"
# Default to the in-repo pinned commit (test262.pin); override with TEST262_COMMIT=<sha>.
PIN="${TEST262_COMMIT:-$(cat test262.pin 2>/dev/null || true)}"
DEST="vendor/test262"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"

if [ "$#" -gt 0 ]; then
  # Partial + sparse checkout: fetch blobs only for the requested paths plus harness/.
  git clone --filter=blob:none --no-checkout "$REPO" "$DEST"
  git -C "$DEST" sparse-checkout init --cone
  git -C "$DEST" sparse-checkout set harness "$@"
  [ -n "$PIN" ] && git -C "$DEST" checkout "$PIN" || git -C "$DEST" checkout
else
  if [ -n "$PIN" ]; then
    git clone --filter=blob:none "$REPO" "$DEST"
    git -C "$DEST" checkout "$PIN"
  else
    git clone --depth 1 "$REPO" "$DEST"
  fi
fi

git -C "$DEST" rev-parse HEAD >"$DEST/.pinned-commit"
echo "vendored test262 @ $(cat "$DEST/.pinned-commit") -> $DEST"
echo "run: zig build test262 -- --path $DEST/test --harness-dir $DEST/harness"
