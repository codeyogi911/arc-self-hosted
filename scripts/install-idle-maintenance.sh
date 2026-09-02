#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LABEL="com.codeyogi911.arc-idle-maintenance"
SOURCE="$ROOT_DIR/launchd/$LABEL.plist"
DESTINATION="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/Library/Application Support/arc-self-hosted/idle-maintenance"

IDLE_MINUTES="${ARC_IDLE_MINUTES:-30}"
MEMORY_THRESHOLD_GIB="${ARC_MEMORY_THRESHOLD_GIB:-16}"
CHECK_INTERVAL_SECONDS="${ARC_CHECK_INTERVAL_SECONDS:-300}"

for setting in "$IDLE_MINUTES" "$MEMORY_THRESHOLD_GIB" "$CHECK_INTERVAL_SECONDS"; do
    if [[ ! "$setting" =~ ^[0-9]+$ ]]; then
        echo "Maintenance settings must be non-negative integers." >&2
        exit 2
    fi
done

if (( MEMORY_THRESHOLD_GIB == 0 || CHECK_INTERVAL_SECONDS < 60 )); then
    echo "Memory threshold must be positive and check interval must be at least 60 seconds." >&2
    exit 2
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"
install -m 0644 "$SOURCE" "$DESTINATION"

plutil -replace ProgramArguments -json \
    "[\"/bin/bash\",\"$SCRIPT_DIR/arc-idle-maintenance.sh\"]" \
    "$DESTINATION"
plutil -replace StartInterval -integer "$CHECK_INTERVAL_SECONDS" "$DESTINATION"
plutil -replace EnvironmentVariables.HOME -string "$HOME" "$DESTINATION"
plutil -replace EnvironmentVariables.ARC_IDLE_MINUTES -string "$IDLE_MINUTES" "$DESTINATION"
plutil -replace EnvironmentVariables.ARC_MEMORY_THRESHOLD_GIB -string "$MEMORY_THRESHOLD_GIB" "$DESTINATION"
plutil -replace EnvironmentVariables.ARC_MAINTENANCE_STATE_DIR -string "$STATE_DIR" "$DESTINATION"
plutil -lint "$DESTINATION"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DESTINATION"

echo "✅ ARC idle maintenance installed."
echo "   Check interval: ${CHECK_INTERVAL_SECONDS}s"
echo "   Required idle time: ${IDLE_MINUTES}m"
echo "   VZ RSS threshold: ${MEMORY_THRESHOLD_GIB} GiB"
echo "   Log: /tmp/arc-idle-maintenance.log"
echo "   Dashboard: $ROOT_DIR/dashboard/index.html"
