#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LABEL="com.codeyogi911.arc-colima"
SOURCE="$ROOT_DIR/launchd/$LABEL.plist"
DESTINATION="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
install -m 0644 "$SOURCE" "$DESTINATION"

# Colima detaches the Lima host agent after starting the VM, so this is an
# intentional one-shot login task.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DESTINATION"

echo "✅ Colima ARC profile will start automatically at login."
