#!/usr/bin/env bash
# Vendor a pinned subset of Node.js's own test suite into vendor/node-test (gitignored),
# recording the exact tag in node-test.pin. This is the corpus for the `node-test` harness
# (spec 104, Unit B) — the host-runtime analogue of vendor-test262.sh.
#
# We sparse-checkout a single pinned LTS tag of nodejs/node and keep only:
#   • test/parallel/test-{buffer,events,util,path,url,querystring,assert,timers,process,net,stream,http}-*.js
#   • test/common/      (the shared harness Node tests `require('../common')`)
#   • test/fixtures/    (data files some of those tests read)
#
# Usage:
#   scripts/vendor-node-test.sh                          # vendor at the pinned tag (node-test.pin)
#   NODE_TEST_TAG=v22.16.0 scripts/vendor-node-test.sh   # override the tag
#
# Idempotent: re-running wipes vendor/node-test and re-fetches. Windows-Git-Bash-friendly.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="https://github.com/nodejs/node.git"
# Default to the in-repo pinned tag (node-test.pin); override with NODE_TEST_TAG=<tag>.
TAG="${NODE_TEST_TAG:-$(cat node-test.pin 2>/dev/null || true)}"
if [ -z "$TAG" ]; then
  echo "error: no Node tag pinned (node-test.pin missing and NODE_TEST_TAG unset)" >&2
  exit 1
fi
DEST="vendor/node-test"

# The test-<mod>-*.js families we keep under test/parallel (everything else is pruned).
MODULES="buffer events util path url querystring assert timers process net stream http"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"

# Shallow, blobless, sparse clone of just the pinned tag — fetch only the trees we need.
git clone --filter=blob:none --no-checkout --depth 1 --branch "$TAG" "$REPO" "$DEST"
git -C "$DEST" sparse-checkout init --cone
git -C "$DEST" sparse-checkout set test/parallel test/common test/fixtures
git -C "$DEST" checkout "$TAG"

# Prune + flatten to the lean layout the runner expects: vendor/node-test/{parallel,common,fixtures}.
# (The runner resolves `require('../common')` relative to parallel/, so parallel and common must be
#  siblings — exactly Node's own layout under test/.)
#
# Node's test/parallel has ~2000+ files; pruning with one subprocess (basename+grep) PER file is
# painfully slow on Windows Git-Bash. Instead we MOVE only the target test-<mod>-*.js files out via
# pure-shell globbing, capture common/fixtures/pin, then wipe the heavy repo root and rebuild.
PIN_SHA="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || echo '?')"
if [ -d "$DEST/test/parallel" ]; then
  STAGE="$(dirname "$DEST")/.node-test-stage.$$"
  rm -rf "$STAGE"; mkdir -p "$STAGE/parallel"
  shopt -s nullglob
  for m in $MODULES; do
    for f in "$DEST"/test/parallel/test-"$m"-*.js; do
      mv "$f" "$STAGE/parallel/" 2>/dev/null || true
    done
  done
  [ -d "$DEST/test/common" ]   && mv "$DEST/test/common"   "$STAGE/common"   || true
  [ -d "$DEST/test/fixtures" ] && mv "$DEST/test/fixtures" "$STAGE/fixtures" || true
  rm -rf "$DEST"
  mv "$STAGE" "$DEST"
fi

printf '%s\n' "$PIN_SHA" >"$DEST/.pinned-commit" 2>/dev/null || true
kept=$(find "$DEST/parallel" -type f -name 'test-*.js' 2>/dev/null | wc -l | tr -d ' ')
echo "vendored nodejs/node @ $TAG ($(cat "$DEST/.pinned-commit" 2>/dev/null || echo '?')) -> $DEST"
echo "kept $kept test/parallel files for modules: $MODULES"
echo "run: scripts/run-node-tests.sh              # all modules"
echo "     scripts/run-node-tests.sh path buffer  # filter by module"
