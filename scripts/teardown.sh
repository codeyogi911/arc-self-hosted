#!/bin/bash
set -euo pipefail

COLIMA_PROFILE="${COLIMA_PROFILE:-arc}"

echo "🗑️  Tearing down ARC and Colima profile '$COLIMA_PROFILE'..."
echo
read -r -p "This deletes the ARC cluster and its local images. Continue? (y/N) " REPLY

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

helm uninstall arc-runner-set -n arc-runners 2>/dev/null || true
helm uninstall arc -n arc-systems 2>/dev/null || true
colima delete --profile "$COLIMA_PROFILE" --force

echo
echo "✅ Teardown complete."
