#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

COLIMA_PROFILE="${ARC_COLIMA_PROFILE:-arc}"
KUBE_CONTEXT="${ARC_KUBE_CONTEXT:-colima-${COLIMA_PROFILE}}"
RUNNER_NAMESPACE="${ARC_RUNNER_NAMESPACE:-arc-runners}"
RUNNER_SET="${ARC_RUNNER_SET:-arc-runner-set}"
IDLE_MINUTES="${ARC_IDLE_MINUTES:-30}"
MEMORY_THRESHOLD_GIB="${ARC_MEMORY_THRESHOLD_GIB:-16}"
CHECK_INTERVAL_SECONDS="${ARC_CHECK_INTERVAL_SECONDS:-300}"
STATE_DIR="${ARC_MAINTENANCE_STATE_DIR:-$HOME/Library/Application Support/arc-self-hosted/idle-maintenance}"

KUBECTL_BIN="${ARC_KUBECTL_BIN:-kubectl}"
PS_BIN="${ARC_PS_BIN:-ps}"
PGREP_BIN="${ARC_PGREP_BIN:-pgrep}"
LSOF_BIN="${ARC_LSOF_BIN:-lsof}"

TEMPLATE="${ARC_DASHBOARD_TEMPLATE:-$ROOT_DIR/dashboard/index.template.html}"
OUTPUT="${ARC_DASHBOARD_OUTPUT:-$ROOT_DIR/dashboard/index.html}"
VM_DISK="${ARC_VM_DISK:-$HOME/.colima/_lima/colima-${COLIMA_PROFILE}/disk}"
IDLE_SINCE_FILE="$STATE_DIR/idle-since"

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

now_epoch() {
    if [[ -n "${ARC_NOW_EPOCH:-}" ]]; then
        printf '%s\n' "$ARC_NOW_EPOCH"
    else
        date +%s
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

CURRENT=0
PENDING=0
RUNNING=0
PODS=0
CLUSTER_OK=0
MEMORY_OK=0
VZ_RSS_KIB=0

if counts="$($KUBECTL_BIN \
    --context "$KUBE_CONTEXT" \
    get autoscalingrunnerset.actions.github.com "$RUNNER_SET" \
    -n "$RUNNER_NAMESPACE" \
    -o 'jsonpath={.status.currentRunners}{" "}{.status.pendingEphemeralRunners}{" "}{.status.runningEphemeralRunners}' \
    2>/dev/null)"; then
    read -r CURRENT PENDING RUNNING <<< "$counts"
    CURRENT="${CURRENT:-0}"
    PENDING="${PENDING:-0}"
    RUNNING="${RUNNING:-0}"

    if is_nonnegative_integer "$CURRENT" && \
        is_nonnegative_integer "$PENDING" && \
        is_nonnegative_integer "$RUNNING"; then
        if pod_names="$($KUBECTL_BIN \
            --context "$KUBE_CONTEXT" \
            get pods \
            -n "$RUNNER_NAMESPACE" \
            -l "actions.github.com/scale-set-name=$RUNNER_SET" \
            --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
            -o name \
            2>/dev/null)"; then
            PODS="$(printf '%s\n' "$pod_names" | awk 'NF { count++ } END { print count + 0 }')"
            CLUSTER_OK=1
        fi
    fi
fi

if vz_pid="$(find_vz_pid)"; then
    if rss="$($PS_BIN -o rss= -p "$vz_pid" 2>/dev/null)"; then
        rss="$(printf '%s\n' "$rss" | awk 'NF { print $1; exit }')"
        if is_nonnegative_integer "$rss"; then
            VZ_RSS_KIB="$rss"
            MEMORY_OK=1
        fi
    fi
fi

CURRENT_EPOCH="$(now_epoch)"
if ! is_nonnegative_integer "$CURRENT_EPOCH"; then
    CURRENT_EPOCH="$(date +%s)"
fi

IDLE_SECONDS=0
IDLE_KNOWN=0
if [[ -f "$IDLE_SINCE_FILE" ]]; then
    idle_since="$(tr -d '[:space:]' < "$IDLE_SINCE_FILE")"
    if is_nonnegative_integer "$idle_since" && (( CURRENT_EPOCH >= idle_since )); then
        IDLE_SECONDS=$(( CURRENT_EPOCH - idle_since ))
        IDLE_KNOWN=1
    fi
fi

BUSY=0
if (( CURRENT > 0 || PENDING > 0 || RUNNING > 0 || PODS > 0 )); then
    BUSY=1
fi

REQUIRED_IDLE_SECONDS=$(( IDLE_MINUTES * 60 ))
THRESHOLD_KIB=$(( MEMORY_THRESHOLD_GIB * 1024 * 1024 ))
IDLE_PROGRESS=0
if (( REQUIRED_IDLE_SECONDS == 0 )); then
    IDLE_PROGRESS=100
elif (( IDLE_KNOWN == 1 )); then
    IDLE_PROGRESS=$(( IDLE_SECONDS * 100 / REQUIRED_IDLE_SECONDS ))
    (( IDLE_PROGRESS > 100 )) && IDLE_PROGRESS=100
fi

MEMORY_PROGRESS=0
if (( MEMORY_OK == 1 )); then
    MEMORY_PROGRESS=$(( VZ_RSS_KIB * 100 / THRESHOLD_KIB ))
    (( MEMORY_PROGRESS > 100 )) && MEMORY_PROGRESS=100
fi

VZ_RSS_GIB="$(awk -v kib="$VZ_RSS_KIB" 'BEGIN { printf "%.1f", kib / 1048576 }')"
IDLE_ELAPSED_MINUTES=$(( IDLE_SECONDS / 60 ))
ACTIVE_TOTAL=$(( CURRENT > PODS ? CURRENT : PODS ))
UPDATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
NEXT_CHECK_EPOCH=$(( CURRENT_EPOCH + CHECK_INTERVAL_SECONDS ))

TONE="safe"
STATUS_LABEL="Protected"
STATUS_TITLE="Restart is blocked"
STATUS_DETAIL="The maintenance guard is refusing to restart the VM."
DECISION="No restart"

CLUSTER_CLASS="wait"
CLUSTER_BADGE="Unknown"
CLUSTER_DETAIL="ARC state could not be read."
RUNNERS_CLASS="wait"
RUNNERS_BADGE="Unknown"
RUNNERS_DETAIL="Runner activity is unavailable."
IDLE_CLASS="wait"
IDLE_BADGE="Waiting"
IDLE_DETAIL="Idle timing has not started."
MEMORY_CLASS="wait"
MEMORY_BADGE="Unknown"
MEMORY_DETAIL="The ARC VZ process has not been measured."
THRESHOLD_CLASS="wait"
THRESHOLD_BADGE="Waiting"
THRESHOLD_DETAIL="Memory eligibility cannot be evaluated yet."

if (( CLUSTER_OK == 0 )); then
    TONE="warning"
    STATUS_LABEL="Fail-safe"
    STATUS_TITLE="ARC state is unavailable"
    STATUS_DETAIL="The VM will not restart while Kubernetes or ARC cannot be inspected."
    DECISION="Restart refused because ARC state is unavailable"
else
    CLUSTER_CLASS="pass"
    CLUSTER_BADGE="Passed"
    CLUSTER_DETAIL="The ARC scale set and runner pods are readable."

    if (( BUSY == 1 )); then
        TONE="busy"
        STATUS_LABEL="Busy"
        STATUS_TITLE="ARC is processing jobs"
        STATUS_DETAIL="At least one assigned, pending, running, or live runner pod is present. The idle timer is reset."
        DECISION="Restart blocked by runner activity"
        RUNNERS_CLASS="block"
        RUNNERS_BADGE="Blocked"
        RUNNERS_DETAIL="current=$CURRENT, pending=$PENDING, running=$RUNNING, pods=$PODS"
        IDLE_CLASS="block"
        IDLE_BADGE="Reset"
        IDLE_DETAIL="The ${IDLE_MINUTES}-minute timer starts only after every runner disappears."
    else
        RUNNERS_CLASS="pass"
        RUNNERS_BADGE="Passed"
        RUNNERS_DETAIL="No assigned runners or active runner pods were found."

        if (( IDLE_KNOWN == 0 )); then
            TONE="waiting"
            STATUS_LABEL="Idle"
            STATUS_TITLE="Starting the idle window"
            STATUS_DETAIL="ARC is idle. The maintenance timer is waiting for ${IDLE_MINUTES} continuous minutes."
            DECISION="Waiting for the idle timer to start"
            IDLE_CLASS="wait"
            IDLE_BADGE="Starting"
            IDLE_DETAIL="The next maintenance check will establish idle progress."
        elif (( IDLE_SECONDS < REQUIRED_IDLE_SECONDS )); then
            TONE="waiting"
            STATUS_LABEL="Cooling down"
            STATUS_TITLE="ARC is idle"
            STATUS_DETAIL="The VM remains online until the ${IDLE_MINUTES}-minute safety window completes."
            DECISION="Waiting for continuous idle time"
            IDLE_CLASS="wait"
            IDLE_BADGE="${IDLE_ELAPSED_MINUTES}m / ${IDLE_MINUTES}m"
            IDLE_DETAIL="Runner activity would reset this timer immediately."
        else
            IDLE_CLASS="pass"
            IDLE_BADGE="Passed"
            IDLE_DETAIL="ARC has remained idle for ${IDLE_ELAPSED_MINUTES} minutes."

            if (( MEMORY_OK == 0 )); then
                TONE="warning"
                STATUS_LABEL="Fail-safe"
                STATUS_TITLE="VZ memory is unavailable"
                STATUS_DETAIL="The VM will not restart unless the ARC VZ process can be identified safely."
                DECISION="Restart refused because VZ memory is unavailable"
            elif (( VZ_RSS_KIB < THRESHOLD_KIB )); then
                TONE="safe"
                STATUS_LABEL="Healthy idle"
                STATUS_TITLE="No memory reclaim needed"
                STATUS_DETAIL="ARC is idle, but retained VZ memory remains below the restart threshold."
                DECISION="No restart because retained memory is below threshold"
                MEMORY_CLASS="pass"
                MEMORY_BADGE="Measured"
                MEMORY_DETAIL="The ARC VZ process is ${VZ_RSS_GIB} GiB RSS."
                THRESHOLD_CLASS="wait"
                THRESHOLD_BADGE="Below threshold"
                THRESHOLD_DETAIL="${VZ_RSS_GIB} GiB retained; restart begins at ${MEMORY_THRESHOLD_GIB} GiB."
            else
                TONE="eligible"
                STATUS_LABEL="Eligible"
                STATUS_TITLE="Memory reclaim conditions passed"
                STATUS_DETAIL="The maintenance job will perform one final ARC recheck immediately before restarting Colima."
                DECISION="Restart eligible pending the final ARC recheck"
                MEMORY_CLASS="pass"
                MEMORY_BADGE="Measured"
                MEMORY_DETAIL="The ARC VZ process is ${VZ_RSS_GIB} GiB RSS."
                THRESHOLD_CLASS="pass"
                THRESHOLD_BADGE="Passed"
                THRESHOLD_DETAIL="Retained memory is at or above ${MEMORY_THRESHOLD_GIB} GiB."
            fi
        fi
    fi
fi

if (( MEMORY_OK == 1 )) && [[ "$MEMORY_CLASS" == "wait" ]]; then
    MEMORY_CLASS="pass"
    MEMORY_BADGE="Measured"
    MEMORY_DETAIL="The ARC VZ process is ${VZ_RSS_GIB} GiB RSS."
fi

export DASH_TONE="$TONE"
export DASH_STATUS_LABEL="$STATUS_LABEL"
export DASH_STATUS_TITLE="$STATUS_TITLE"
export DASH_STATUS_DETAIL="$STATUS_DETAIL"
export DASH_DECISION="$DECISION"
export DASH_UPDATED_AT="$UPDATED_AT"
export DASH_UPDATED_EPOCH="$CURRENT_EPOCH"
export DASH_NEXT_CHECK_EPOCH="$NEXT_CHECK_EPOCH"
export DASH_CHECK_INTERVAL="$CHECK_INTERVAL_SECONDS"
export DASH_CURRENT="$CURRENT"
export DASH_PENDING="$PENDING"
export DASH_RUNNING="$RUNNING"
export DASH_PODS="$PODS"
export DASH_ACTIVE_TOTAL="$ACTIVE_TOTAL"
export DASH_RSS_GIB="$VZ_RSS_GIB"
export DASH_MEMORY_THRESHOLD="$MEMORY_THRESHOLD_GIB"
export DASH_MEMORY_PROGRESS="$MEMORY_PROGRESS"
export DASH_IDLE_MINUTES="$IDLE_ELAPSED_MINUTES"
export DASH_IDLE_REQUIRED="$IDLE_MINUTES"
export DASH_IDLE_PROGRESS="$IDLE_PROGRESS"
export DASH_CLUSTER_CLASS="$CLUSTER_CLASS"
export DASH_CLUSTER_BADGE="$CLUSTER_BADGE"
export DASH_CLUSTER_DETAIL="$CLUSTER_DETAIL"
export DASH_RUNNERS_CLASS="$RUNNERS_CLASS"
export DASH_RUNNERS_BADGE="$RUNNERS_BADGE"
export DASH_RUNNERS_DETAIL="$RUNNERS_DETAIL"
export DASH_IDLE_CLASS="$IDLE_CLASS"
export DASH_IDLE_BADGE="$IDLE_BADGE"
export DASH_IDLE_DETAIL="$IDLE_DETAIL"
export DASH_MEMORY_CLASS="$MEMORY_CLASS"
export DASH_MEMORY_BADGE="$MEMORY_BADGE"
export DASH_MEMORY_DETAIL="$MEMORY_DETAIL"
export DASH_THRESHOLD_CLASS="$THRESHOLD_CLASS"
export DASH_THRESHOLD_BADGE="$THRESHOLD_BADGE"
export DASH_THRESHOLD_DETAIL="$THRESHOLD_DETAIL"

mkdir -p "$(dirname "$OUTPUT")"
TEMP_OUTPUT="$(mktemp "$(dirname "$OUTPUT")/.arc-dashboard.XXXXXX")"
trap 'rm -f "$TEMP_OUTPUT"' EXIT

awk '
{
    gsub(/__TONE__/, ENVIRON["DASH_TONE"])
    gsub(/__STATUS_LABEL__/, ENVIRON["DASH_STATUS_LABEL"])
    gsub(/__STATUS_TITLE__/, ENVIRON["DASH_STATUS_TITLE"])
    gsub(/__STATUS_DETAIL__/, ENVIRON["DASH_STATUS_DETAIL"])
    gsub(/__DECISION__/, ENVIRON["DASH_DECISION"])
    gsub(/__UPDATED_AT__/, ENVIRON["DASH_UPDATED_AT"])
    gsub(/__UPDATED_EPOCH__/, ENVIRON["DASH_UPDATED_EPOCH"])
    gsub(/__NEXT_CHECK_EPOCH__/, ENVIRON["DASH_NEXT_CHECK_EPOCH"])
    gsub(/__CHECK_INTERVAL__/, ENVIRON["DASH_CHECK_INTERVAL"])
    gsub(/__CURRENT__/, ENVIRON["DASH_CURRENT"])
    gsub(/__PENDING__/, ENVIRON["DASH_PENDING"])
    gsub(/__RUNNING__/, ENVIRON["DASH_RUNNING"])
    gsub(/__PODS__/, ENVIRON["DASH_PODS"])
    gsub(/__ACTIVE_TOTAL__/, ENVIRON["DASH_ACTIVE_TOTAL"])
    gsub(/__RSS_GIB__/, ENVIRON["DASH_RSS_GIB"])
    gsub(/__MEMORY_THRESHOLD__/, ENVIRON["DASH_MEMORY_THRESHOLD"])
    gsub(/__MEMORY_PROGRESS__/, ENVIRON["DASH_MEMORY_PROGRESS"])
    gsub(/__IDLE_MINUTES__/, ENVIRON["DASH_IDLE_MINUTES"])
    gsub(/__IDLE_REQUIRED__/, ENVIRON["DASH_IDLE_REQUIRED"])
    gsub(/__IDLE_PROGRESS__/, ENVIRON["DASH_IDLE_PROGRESS"])
    gsub(/__CLUSTER_CLASS__/, ENVIRON["DASH_CLUSTER_CLASS"])
    gsub(/__CLUSTER_BADGE__/, ENVIRON["DASH_CLUSTER_BADGE"])
    gsub(/__CLUSTER_DETAIL__/, ENVIRON["DASH_CLUSTER_DETAIL"])
    gsub(/__RUNNERS_CLASS__/, ENVIRON["DASH_RUNNERS_CLASS"])
    gsub(/__RUNNERS_BADGE__/, ENVIRON["DASH_RUNNERS_BADGE"])
    gsub(/__RUNNERS_DETAIL__/, ENVIRON["DASH_RUNNERS_DETAIL"])
    gsub(/__IDLE_CLASS__/, ENVIRON["DASH_IDLE_CLASS"])
    gsub(/__IDLE_BADGE__/, ENVIRON["DASH_IDLE_BADGE"])
    gsub(/__IDLE_DETAIL__/, ENVIRON["DASH_IDLE_DETAIL"])
    gsub(/__MEMORY_CLASS__/, ENVIRON["DASH_MEMORY_CLASS"])
    gsub(/__MEMORY_BADGE__/, ENVIRON["DASH_MEMORY_BADGE"])
    gsub(/__MEMORY_DETAIL__/, ENVIRON["DASH_MEMORY_DETAIL"])
    gsub(/__THRESHOLD_CLASS__/, ENVIRON["DASH_THRESHOLD_CLASS"])
    gsub(/__THRESHOLD_BADGE__/, ENVIRON["DASH_THRESHOLD_BADGE"])
    gsub(/__THRESHOLD_DETAIL__/, ENVIRON["DASH_THRESHOLD_DETAIL"])
    print
}' "$TEMPLATE" > "$TEMP_OUTPUT"

mv "$TEMP_OUTPUT" "$OUTPUT"
trap - EXIT

printf '%s\n' "$OUTPUT"
