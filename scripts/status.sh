#!/bin/bash
set -euo pipefail

echo "📊 ARC Deployment Status"
echo "========================"
echo ""

echo "🔹 Colima Runtime:"
colima status --profile "${COLIMA_PROFILE:-arc}" --extended 2>/dev/null || echo "   ❌ Colima profile is not running"
echo ""

# Check cluster
echo "🔹 Kubernetes Cluster:"
if kubectl cluster-info &> /dev/null; then
    kubectl config current-context
    echo ""
else
    echo "   ❌ Not connected to cluster"
    exit 1
fi

# Helm releases
echo "🔹 Helm Releases:"
helm list -A
echo ""

# Controller pods
echo "🔹 Controller Pods (arc-systems):"
kubectl get pods -n arc-systems 2>/dev/null || echo "   No pods found"
echo ""

# Runner pods
echo "🔹 Runner Pods (arc-runners):"
kubectl get pods -n arc-runners 2>/dev/null || echo "   No active runners (this is normal when no jobs are running)"
echo ""

# Secrets
echo "🔹 Secrets (arc-runners):"
kubectl get secrets -n arc-runners 2>/dev/null || echo "   No secrets found"
echo ""

# Recent events
echo "🔹 Recent Events:"
kubectl get events -n arc-systems --sort-by='.lastTimestamp' 2>/dev/null | tail -5
