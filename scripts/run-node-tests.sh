#!/usr/bin/env bash
# node-test harness runner (spec 104, Unit B). Builds the ljs host runtime, then runs each
# vendored Node test (vendor/node-test/parallel/test-<mod>-*.js) via `ljs run` and classifies:
#   exit 0            -> PASS
#   non-zero / timeout -> FAIL  (first stderr line recorded as the reason)
# Tallies per module + overall and prints a report; also writes vendor/node-test/report.txt.
#
# Usage:
#   scripts/run-node-tests.sh                 # all vendored modules
#   scripts/run-node-tests.sh path buffer     # only test-path-* and test-buffer-*
#   scripts/run-node-tests.sh --shim          # use the minimal common shim (see below)
#   scripts/run-node-tests.sh --shim path     # shim + module filter
#   TIMEOUT=20 scripts/run-node-tests.sh      # per-test timeout seconds (default 10)
#
# --shim: Node's real test/common/index.js leans on host features ljs lacks (internal bindings,
#   process.on('exit') for mustCall accounting) and may THROW on load, failing every test that
#   requires('../common') before its own asserts run. With --shim we OVERLAY a minimal shim at
#   vendor/node-test/common/index.js (backing up the real one to index.js.real) so that
#   require('../common') resolves to our shim — letting pure synchronous-assert tests (path,
#   buffer, querystring) actually exercise the assertion and PASS. Re-running WITHOUT --shim
#   restores the real common from the backup. The shim source lives at
#   scripts/node-test-common-shim.js (vendored copy of the canonical shim).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
DEST="vendor/node-test"
PARALLEL="$DEST/parallel"
COMMON_DIR="$DEST/common"
SHIM_SRC="scripts/node-test-common-shim.js"
REPORT="$DEST/report.txt"
TIMEOUT="${TIMEOUT:-10}"

# ---- parse args: optional --shim flag, then module-name filters --------------------------------
USE_SHIM=0
FILTERS=()
for a in "$@"; do
  case "$a" in
    --shim) USE_SHIM=1 ;;
    --*)    echo "unknown flag: $a" >&2; exit 2 ;;
    *)      FILTERS+=("$a") ;;
  esac
done

# ---- build the host runtime + locate the freshest ljs.exe -------------------------------------
echo "building ljs ..." >&2
zig build >&2
LJS="$(ls -t .zig-cache/o/*/ljs.exe 2>/dev/null | head -1 || true)"
[ -z "$LJS" ] && LJS="$(ls -t zig-out/bin/ljs.exe 2>/dev/null | head -1 || true)"
if [ -z "$LJS" ] || [ ! -x "$LJS" ]; then
  echo "error: could not find a built ljs.exe (run: zig build)" >&2
  exit 1
fi
echo "using ljs: $LJS" >&2

if [ ! -d "$PARALLEL" ]; then
  echo "error: $PARALLEL not found — run scripts/vendor-node-test.sh first" >&2
  exit 1
fi

# ---- optional common shim overlay (and restore when not requested) ----------------------------
overlay_shim() {
  [ -d "$COMMON_DIR" ] || mkdir -p "$COMMON_DIR"
  if [ -f "$COMMON_DIR/index.js" ] && [ ! -f "$COMMON_DIR/index.js.real" ]; then
    mv "$COMMON_DIR/index.js" "$COMMON_DIR/index.js.real"
  fi
  cp "$SHIM_SRC" "$COMMON_DIR/index.js"
  echo "using common shim ($SHIM_SRC -> $COMMON_DIR/index.js)" >&2
}
restore_common() {
  if [ -f "$COMMON_DIR/index.js.real" ]; then
    mv -f "$COMMON_DIR/index.js.real" "$COMMON_DIR/index.js"
    echo "restored real common/index.js" >&2
  fi
}
if [ "$USE_SHIM" = "1" ]; then
  if [ ! -f "$SHIM_SRC" ]; then
    echo "error: shim source $SHIM_SRC missing" >&2; exit 1
  fi
  overlay_shim
else
  restore_common
fi

# ---- collect the test files (apply module filters if any) -------------------------------------
collect() {
  if [ "${#FILTERS[@]}" -eq 0 ]; then
    find "$PARALLEL" -type f -name 'test-*.js' | sort
  else
    for m in "${FILTERS[@]}"; do
      find "$PARALLEL" -type f -name "test-${m}-*.js"
    done | sort -u
  fi
}

# A portable per-test timeout: prefer coreutils `timeout`, else fall back to no-timeout run.
have_timeout=0
command -v timeout >/dev/null 2>&1 && have_timeout=1

run_one() {
  local f="$1" err_file rc
  err_file="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/ljs-nt-$$.err")"
  if [ "$have_timeout" = "1" ]; then
    timeout -k 2 "$TIMEOUT" "$LJS" run "$f" >/dev/null 2>"$err_file"
    rc=$?
  else
    "$LJS" run "$f" >/dev/null 2>"$err_file"
    rc=$?
  fi
  # First non-empty stderr line as the reason (truncated).
  REASON="$(grep -m1 . "$err_file" 2>/dev/null | cut -c1-100 || true)"
  rm -f "$err_file"
  return $rc
}

# ---- run + tally ------------------------------------------------------------------------------
declare -A MOD_PASS MOD_TOTAL
TOTAL_PASS=0 TOTAL=0
: >"$REPORT.detail"

module_of() {
  # test-<mod>-rest.js -> <mod>
  basename "$1" | sed -E 's/^test-([a-z0-9]+)-.*/\1/'
}

while IFS= read -r f; do
  [ -z "$f" ] && continue
  mod="$(module_of "$f")"
  TOTAL=$((TOTAL + 1))
  MOD_TOTAL[$mod]=$(( ${MOD_TOTAL[$mod]:-0} + 1 ))
  REASON=""
  if run_one "$f"; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
    MOD_PASS[$mod]=$(( ${MOD_PASS[$mod]:-0} + 1 ))
    printf 'PASS  %s\n' "${f#"$DEST"/}" >>"$REPORT.detail"
  else
    rc=$?
    if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then REASON="timeout (${TIMEOUT}s)"; fi
    printf 'FAIL  %s  :: %s\n' "${f#"$DEST"/}" "${REASON:-exit $rc}" >>"$REPORT.detail"
  fi
done < <(collect)

# ---- format the report ------------------------------------------------------------------------
pct() { # pass total -> "(NN.N%)"
  local p="$1" t="$2"
  if [ "$t" -eq 0 ]; then echo "(  n/a)"; return; fi
  awk -v p="$p" -v t="$t" 'BEGIN{ printf("(%4.1f%%)", (p*100.0)/t) }'
}

{
  echo "node-test harness — nodejs/node @ $(cat node-test.pin 2>/dev/null || echo '?')"
  [ "$USE_SHIM" = "1" ] && echo "(common shim active)"
  echo "------------------------------------------------"
  for mod in $(printf '%s\n' "${!MOD_TOTAL[@]}" | sort); do
    p=${MOD_PASS[$mod]:-0}; t=${MOD_TOTAL[$mod]}
    printf '%-11s : %d/%d %s\n' "$mod" "$p" "$t" "$(pct "$p" "$t")"
  done
  echo "------------------------------------------------"
  printf '%-11s : %d/%d %s\n' "TOTAL" "$TOTAL_PASS" "$TOTAL" "$(pct "$TOTAL_PASS" "$TOTAL")"
} | tee "$REPORT"

echo "" >&2
echo "per-test detail: $REPORT.detail" >&2
echo "summary report : $REPORT" >&2
