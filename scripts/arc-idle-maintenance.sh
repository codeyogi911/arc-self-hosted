#!/bin/bash
set -euo pipefail

MODE="run"
if [[ "${ARC_DRY_RUN:-0}" == "1" ]]; then
    MODE="dry-run"
fi
case "${1:-}" in
    "") ;;
    --check|--dry-run)
        MODE="dry-run"
        ;;
    *)
        echo "Usage: $0 [--check|--dry-run]" >&2
        exit 2
        ;;
esac

COLIMA_PROFILE="${ARC_COLIMA_PROFILE:-arc}"
KUBE_CONTEXT="${ARC_KUBE_CONTEXT:-colima-${COLIMA_PROFILE}}"
RUNNER_NAMESPACE="${ARC_RUNNER_NAMESPACE:-arc-runners}"
RUNNER_SET="${ARC_RUNNER_SET:-arc-runner-set}"
IDLE_MINUTES="${ARC_IDLE_MINUTES:-30}"
MEMORY_THRESHOLD_GIB="${ARC_MEMORY_THRESHOLD_GIB:-16}"
STATE_DIR="${ARC_MAINTENANCE_STATE_DIR:-$HOME/Library/Application Support/arc-self-hosted/idle-maintenance}"

KUBECTL_BIN="${ARC_KUBECTL_BIN:-kubectl}"
COLIMA_BIN="${ARC_COLIMA_BIN:-colima}"
PS_BIN="${ARC_PS_BIN:-ps}"
PGREP_BIN="${ARC_PGREP_BIN:-pgrep}"
LSOF_BIN="${ARC_LSOF_BIN:-lsof}"

IDLE_SINCE_FILE="$STATE_DIR/idle-since"
LOCK_DIR="$STATE_DIR/lock"
VM_DISK="${ARC_VM_DISK:-$HOME/.colima/_lima/colima-${COLIMA_PROFILE}/disk}"
DASHBOARD_UPDATER="${ARC_DASHBOARD_UPDATER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-dashboard.sh}"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

for setting in "$IDLE_MINUTES" "$MEMORY_THRESHOLD_GIB"; do
    if ! is_nonnegative_integer "$setting"; then
        echo "Idle minutes and memory threshold must be non-negative integers." >&2
        exit 2
    fi
done

if (( MEMORY_THRESHOLD_GIB == 0 )); then
    echo "Memory threshold must be greater than zero." >&2
    exit 2
fi

mkdir -p "$STATE_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another maintenance check is already running; skipping."
    exit 0
fi
cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if [[ "${ARC_DASHBOARD_ENABLED:-1}" == "1" && -x "$DASHBOARD_UPDATER" ]]; then
        "$DASHBOARD_UPDATER" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

now_epoch() {
    if [[ -n "${ARC_NOW_EPOCH:-}" ]]; then
        printf '%s\n' "$ARC_NOW_EPOCH"
    else
        date +%s
    fi
}

ARC_CURRENT=0
ARC_PENDING=0
ARC_RUNNING=0
ARC_PODS=0

read_arc_state() {
    local counts pod_names

    if ! counts="$($KUBECTL_BIN \
        --context "$KUBE_CONTEXT" \
        get autoscalingrunnerset.actions.github.com "$RUNNER_SET" \
        -n "$RUNNER_NAMESPACE" \
        -o 'jsonpath={.status.currentRunners}{" "}{.status.pendingEphemeralRunners}{" "}{.status.runningEphemeralRunners}' \
        2>/dev/null)"; then
        return 1
    fi

    read -r ARC_CURRENT ARC_PENDING ARC_RUNNING <<< "$counts"
    ARC_CURRENT="${ARC_CURRENT:-0}"
    ARC_PENDING="${ARC_PENDING:-0}"
    ARC_RUNNING="${ARC_RUNNING:-0}"

    for count in "$ARC_CURRENT" "$ARC_PENDING" "$ARC_RUNNING"; do
        if ! is_nonnegative_integer "$count"; then
            return 1
        fi
    done

    if ! pod_names="$($KUBECTL_BIN \
        --context "$KUBE_CONTEXT" \
        get pods \
        -n "$RUNNER_NAMESPACE" \
        -l "actions.github.com/scale-set-name=$RUNNER_SET" \
        --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
        -o name \
        2>/dev/null)"; then
        return 1
    fi

    ARC_PODS="$(printf '%s\n' "$pod_names" | awk 'NF { count++ } END { print count + 0 }')"
}

arc_is_busy() {
    (( ARC_CURRENT > 0 || ARC_PENDING > 0 || ARC_RUNNING > 0 || ARC_PODS > 0 ))
}

reset_idle_timer() {
    if [[ "$MODE" == "run" ]]; then
        rm -f "$IDLE_SINCE_FILE"
    fi
}

find_vz_pid() {
    local candidate

    if [[ -n "${ARC_VZ_PID:-}" ]]; then
        if is_nonnegative_integer "$ARC_VZ_PID"; then
            printf '%s\n' "$ARC_VZ_PID"
            return 0
        fi
        return 1
    fi

    while IFS= read -r candidate; do
        if "$LSOF_BIN" -a -p "$candidate" -Fn 2>/dev/null | grep -Fqx "n$VM_DISK"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <("$PGREP_BIN" -f '/com.apple.Virtualization.VirtualMachine$' 2>/dev/null || true)

    return 1
}

read_vz_rss_kib() {
    local vz_pid rss

    if ! vz_pid="$(find_vz_pid)"; then
        return 1
    fi

    if ! rss="$($PS_BIN -o rss= -p "$vz_pid" 2>/dev/null)"; then
        return 1
    fi

    rss="$(printf '%s\n' "$rss" | awk 'NF { print $1; exit }')"
    if ! is_nonnegative_integer "$rss"; then
        return 1
    fi

    printf '%s\n' "$rss"
}

if ! read_arc_state; then
    log "ARC state is unavailable; refusing to restart Colima."
    exit 0
fi

if arc_is_busy; then
    reset_idle_timer
    log "ARC is busy (current=$ARC_CURRENT pending=$ARC_PENDING running=$ARC_RUNNING pods=$ARC_PODS); idle timer reset."
    exit 0
fi

current_epoch="$(now_epoch)"
if ! is_nonnegative_integer "$current_epoch"; then
    log "Current time is invalid; refusing maintenance."
    exit 1
fi

if [[ ! -f "$IDLE_SINCE_FILE" ]]; then
    if [[ "$MODE" == "run" ]]; then
        printf '%s\n' "$current_epoch" > "$IDLE_SINCE_FILE"
        log "ARC became idle; starting the ${IDLE_MINUTES}-minute idle timer."
    else
        log "ARC is idle; a live run would start the ${IDLE_MINUTES}-minute idle timer."
    fi
    exit 0
fi

idle_since="$(tr -d '[:space:]' < "$IDLE_SINCE_FILE")"
if ! is_nonnegative_integer "$idle_since"; then
    if [[ "$MODE" == "run" ]]; then
        printf '%s\n' "$current_epoch" > "$IDLE_SINCE_FILE"
    fi
    log "Idle timer state was invalid; timer reset."
    exit 0
fi

idle_seconds=$(( current_epoch - idle_since ))
required_idle_seconds=$(( IDLE_MINUTES * 60 ))
if (( idle_seconds < required_idle_seconds )); then
    log "ARC is idle for $(( idle_seconds / 60 ))m; waiting for ${IDLE_MINUTES}m."
    exit 0
fi

if ! vz_rss_kib="$(read_vz_rss_kib)"; then
    log "Could not identify the ARC VZ process; refusing to restart Colima."
    exit 0
fi

threshold_kib=$(( MEMORY_THRESHOLD_GIB * 1024 * 1024 ))
vz_rss_gib="$(awk -v kib="$vz_rss_kib" 'BEGIN { printf "%.1f", kib / 1048576 }')"
if (( vz_rss_kib < threshold_kib )); then
    log "ARC is idle, but VZ RSS is ${vz_rss_gib} GiB (threshold ${MEMORY_THRESHOLD_GIB} GiB); no restart needed."
    exit 0
fi

# Close the race between the initial idle check and the restart decision.
if ! read_arc_state || arc_is_busy; then
    reset_idle_timer
    log "ARC activity appeared during the maintenance check; restart cancelled."
    exit 0
fi

if [[ "$MODE" == "dry-run" ]]; then
    log "DRY RUN: ARC is idle and VZ RSS is ${vz_rss_gib} GiB; Colima profile '$COLIMA_PROFILE' would restart."
    exit 0
fi

log "ARC is idle and VZ RSS is ${vz_rss_gib} GiB; restarting Colima profile '$COLIMA_PROFILE'."
if ! "$COLIMA_BIN" restart "$COLIMA_PROFILE"; then
    printf '%s\n' "$current_epoch" > "$IDLE_SINCE_FILE"
    log "Colima restart failed; maintenance timer restarted to avoid a retry loop."
    exit 1
fi

rm -f "$IDLE_SINCE_FILE"
if ! "$KUBECTL_BIN" --context "$KUBE_CONTEXT" wait --for=condition=Ready node --all --timeout=180s; then
    log "Colima restarted, but the Kubernetes readiness check timed out."
    exit 1
fi

log "Colima restart completed and Kubernetes is ready."
