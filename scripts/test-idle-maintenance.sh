#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MAINTENANCE_SCRIPT="$SCRIPT_DIR/arc-idle-maintenance.sh"
FAKE_BIN="$ROOT_DIR/test/fixtures/idle-maintenance"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/arc-idle-maintenance.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0

assert_contains() {
    local output="$1" expected="$2"
    if [[ "$output" != *"$expected"* ]]; then
        echo "Expected output to contain: $expected" >&2
        echo "$output" >&2
        exit 1
    fi
}

assert_no_restart() {
    local call_log="$1"
    if [[ -s "$call_log" ]]; then
        echo "Unexpected Colima call:" >&2
        cat "$call_log" >&2
        exit 1
    fi
}

run_maintenance() {
    local state_dir="$1" call_log="$2"
    shift 2

    env \
        ARC_KUBECTL_BIN="$FAKE_BIN/kubectl" \
        ARC_COLIMA_BIN="$FAKE_BIN/colima" \
        ARC_PS_BIN="$FAKE_BIN/ps" \
        ARC_VZ_PID=999 \
        ARC_DASHBOARD_ENABLED=0 \
        ARC_MAINTENANCE_STATE_DIR="$state_dir" \
        FAKE_COLIMA_LOG="$call_log" \
        "$@" \
        "$MAINTENANCE_SCRIPT"
}

new_case() {
    CASE_DIR="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
    STATE_DIR="$CASE_DIR/state"
    CALL_LOG="$CASE_DIR/colima-calls"
    mkdir -p "$STATE_DIR"
    : > "$CALL_LOG"
}

new_case
output="$(run_maintenance "$STATE_DIR" "$CALL_LOG" \
    FAKE_ARC_COUNTS='5 1 4' FAKE_POD_COUNT=5 \
    ARC_NOW_EPOCH=1000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16)"
assert_contains "$output" "ARC is busy"
assert_no_restart "$CALL_LOG"
(( PASS_COUNT += 1 ))

new_case
output="$(run_maintenance "$STATE_DIR" "$CALL_LOG" \
    FAKE_ARC_COUNTS='0 0 0' FAKE_POD_COUNT=0 \
    ARC_NOW_EPOCH=1000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16)"
assert_contains "$output" "starting the 30-minute idle timer"
[[ "$(tr -d '[:space:]' < "$STATE_DIR/idle-since")" == "1000" ]]
assert_no_restart "$CALL_LOG"
(( PASS_COUNT += 1 ))

new_case
printf '1000\n' > "$STATE_DIR/idle-since"
output="$(run_maintenance "$STATE_DIR" "$CALL_LOG" \
    FAKE_ARC_COUNTS='0 0 0' FAKE_POD_COUNT=0 FAKE_RSS_KIB=15728640 \
    ARC_NOW_EPOCH=4000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16)"
assert_contains "$output" "no restart needed"
assert_no_restart "$CALL_LOG"
(( PASS_COUNT += 1 ))

new_case
printf '1000\n' > "$STATE_DIR/idle-since"
output="$(run_maintenance "$STATE_DIR" "$CALL_LOG" \
    FAKE_ARC_COUNTS='0 0 0' FAKE_POD_COUNT=0 FAKE_RSS_KIB=17825792 \
    ARC_NOW_EPOCH=4000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16 \
    ARC_DRY_RUN=1)"
assert_contains "$output" "DRY RUN"
assert_no_restart "$CALL_LOG"
(( PASS_COUNT += 1 ))

new_case
printf '1000\n' > "$STATE_DIR/idle-since"
output="$(run_maintenance "$STATE_DIR" "$CALL_LOG" \
    FAKE_ARC_COUNTS='0 0 0' FAKE_POD_COUNT=0 FAKE_RSS_KIB=17825792 \
    ARC_NOW_EPOCH=4000 ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16)"
assert_contains "$output" "restart completed"
grep -Fxq "restart arc" "$CALL_LOG"
[[ ! -f "$STATE_DIR/idle-since" ]]
(( PASS_COUNT += 1 ))

new_case
output="$(run_maintenance "$STATE_DIR" "$CALL_LOG" \
    FAKE_KUBECTL_FAIL=1 ARC_NOW_EPOCH=1000 \
    ARC_IDLE_MINUTES=30 ARC_MEMORY_THRESHOLD_GIB=16)"
assert_contains "$output" "ARC state is unavailable"
assert_no_restart "$CALL_LOG"
(( PASS_COUNT += 1 ))

echo "✅ $PASS_COUNT idle-maintenance tests passed."
