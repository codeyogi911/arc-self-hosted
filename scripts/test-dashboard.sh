#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FAKE_BIN="$ROOT_DIR/test/fixtures/idle-maintenance"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/arc-dashboard.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

render() {
    local output="$1" state_dir="$2"
    shift 2

    env \
        ARC_KUBECTL_BIN="$FAKE_BIN/kubectl" \
        ARC_PS_BIN="$FAKE_BIN/ps" \
        ARC_VZ_PID=999 \
        ARC_MAINTENANCE_STATE_DIR="$state_dir" \
        ARC_DASHBOARD_OUTPUT="$output" \
        "$@" \
        "$SCRIPT_DIR/update-dashboard.sh" >/dev/null
}

BUSY_STATE="$TEST_ROOT/busy-state"
BUSY_OUTPUT="$TEST_ROOT/busy.html"
mkdir -p "$BUSY_STATE"
render "$BUSY_OUTPUT" "$BUSY_STATE" \
    FAKE_ARC_COUNTS='5 1 4' FAKE_POD_COUNT=5 FAKE_RSS_KIB=14680064 \
    ARC_NOW_EPOCH=4000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16
grep -Fq "ARC is processing jobs" "$BUSY_OUTPUT"
grep -Fq "current=5, pending=1, running=4, pods=5" "$BUSY_OUTPUT"

ELIGIBLE_STATE="$TEST_ROOT/eligible-state"
ELIGIBLE_OUTPUT="$TEST_ROOT/eligible.html"
mkdir -p "$ELIGIBLE_STATE"
printf '1000\n' > "$ELIGIBLE_STATE/idle-since"
render "$ELIGIBLE_OUTPUT" "$ELIGIBLE_STATE" \
    FAKE_ARC_COUNTS='0 0 0' FAKE_POD_COUNT=0 FAKE_RSS_KIB=17825792 \
    ARC_NOW_EPOCH=4000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16
grep -Fq "Memory reclaim conditions passed" "$ELIGIBLE_OUTPUT"
grep -Fq "Restart eligible pending the final ARC recheck" "$ELIGIBLE_OUTPUT"

if rg -q '__[A-Z][A-Z_]+__' "$BUSY_OUTPUT" "$ELIGIBLE_OUTPUT"; then
    echo "Dashboard contains unresolved template tokens." >&2
    exit 1
fi

if command -v xmllint >/dev/null 2>&1; then
    xmllint --html --noout "$BUSY_OUTPUT" "$ELIGIBLE_OUTPUT" 2>/dev/null
fi

echo "✅ Dashboard busy and restart-eligible states passed."
