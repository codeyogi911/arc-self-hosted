#!/bin/bash

CLUSTER_NAME="arc-cluster"

echo "🗑️  Tearing down ARC deployment..."
echo ""

read -p "This will delete the entire cluster. Continue? (y/N) " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Uninstall Helm releases
echo "📦 Uninstalling Helm releases..."
helm uninstall arc-runner-set -n arc-runners 2>/dev/null || true
helm uninstall arc -n arc-systems 2>/dev/null || true

# Delete cluster
echo "🗑️  Deleting cluster..."
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true

echo ""
echo "✅ Teardown complete!"

