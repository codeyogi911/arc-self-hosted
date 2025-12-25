#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTROLLER_NAMESPACE="arc-systems"
RUNNER_NAMESPACE="arc-runners"

echo "🔄 Upgrading Actions Runner Controller..."
echo ""

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster."
    exit 1
fi

echo "⚠️  This will cause temporary downtime for your runners."
echo "   All queued jobs will wait until ARC is back online."
echo ""
read -p "Continue with upgrade? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Step 1: Uninstall runner scale sets
echo ""
echo "📦 Step 1/4: Uninstalling runner scale sets..."
for release in $(helm list -n "$RUNNER_NAMESPACE" -q 2>/dev/null); do
    echo "   Uninstalling $release..."
    helm uninstall "$release" -n "$RUNNER_NAMESPACE" --wait 2>/dev/null || true
done

# Step 2: Wait for resources cleanup
echo ""
echo "⏳ Step 2/4: Waiting for resources cleanup..."
kubectl delete pods -n "$RUNNER_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true
kubectl delete ephemeralrunnersets -n "$RUNNER_NAMESPACE" --all 2>/dev/null || true

for i in {1..30}; do
    if ! kubectl get autoscalingrunnersets -n "$RUNNER_NAMESPACE" 2>/dev/null | grep -q .; then
        echo "   Resources cleaned up."
        break
    fi
    echo "   Waiting... ($i/30)"
    sleep 2
done

# Step 3: Uninstall ARC controller
echo ""
echo "📦 Step 3/4: Uninstalling ARC controller..."
helm uninstall arc -n "$CONTROLLER_NAMESPACE" --wait 2>/dev/null || true

for i in {1..30}; do
    if ! kubectl get pods -n "$CONTROLLER_NAMESPACE" 2>/dev/null | grep -q "arc-"; then
        echo "   Controller removed."
        break
    fi
    sleep 2
done

# Remove CRDs for clean upgrade
echo "   Removing CRDs..."
kubectl delete crd autoscalinglisteners.actions.github.com 2>/dev/null || true
kubectl delete crd autoscalingrunnersets.actions.github.com 2>/dev/null || true
kubectl delete crd ephemeralrunners.actions.github.com 2>/dev/null || true
kubectl delete crd ephemeralrunnersets.actions.github.com 2>/dev/null || true

# Step 4: Reinstall using deploy script
echo ""
echo "📦 Step 4/4: Reinstalling ARC..."
"$SCRIPT_DIR/deploy-arc.sh"

echo ""
echo "🎉 ARC upgrade complete!"
