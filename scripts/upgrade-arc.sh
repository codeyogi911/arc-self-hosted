#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONTROLLER_NAMESPACE="arc-systems"
RUNNER_NAMESPACE="arc-runners"

# GitHub Config URL - required for reinstall
GITHUB_CONFIG_URL="${GITHUB_CONFIG_URL:-}"

echo "🔄 Upgrading Actions Runner Controller..."
echo ""

# Check if GITHUB_CONFIG_URL is set
if [[ -z "$GITHUB_CONFIG_URL" ]]; then
    echo "❌ GITHUB_CONFIG_URL is not set!"
    echo ""
    echo "Set it before running this script:"
    echo "  export GITHUB_CONFIG_URL=https://github.com/YOUR_ORG"
    exit 1
fi

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
echo "📦 Step 1/5: Uninstalling runner scale sets..."
for release in $(helm list -n "$RUNNER_NAMESPACE" -q 2>/dev/null); do
    echo "   Uninstalling $release..."
    helm uninstall "$release" -n "$RUNNER_NAMESPACE" --wait 2>/dev/null || true
done

# Step 2: Wait for resources cleanup
echo ""
echo "⏳ Step 2/5: Waiting for resources cleanup..."
echo "   Waiting for runner pods to terminate..."
kubectl delete pods -n "$RUNNER_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true

# Wait for ephemeral runner sets to be deleted
for i in {1..30}; do
    if ! kubectl get ephemeralrunnersets -n "$RUNNER_NAMESPACE" 2>/dev/null | grep -q .; then
        echo "   All ephemeral runner sets cleaned up."
        break
    fi
    echo "   Waiting for ephemeral runner sets... ($i/30)"
    kubectl delete ephemeralrunnersets -n "$RUNNER_NAMESPACE" --all 2>/dev/null || true
    sleep 2
done

# Wait for autoscaling runner sets to be deleted
for i in {1..30}; do
    if ! kubectl get autoscalingrunnersets -n "$RUNNER_NAMESPACE" 2>/dev/null | grep -q .; then
        echo "   All autoscaling runner sets cleaned up."
        break
    fi
    echo "   Waiting for autoscaling runner sets... ($i/30)"
    sleep 2
done

# Step 3: Uninstall ARC controller
echo ""
echo "📦 Step 3/5: Uninstalling ARC controller..."
helm uninstall arc -n "$CONTROLLER_NAMESPACE" --wait 2>/dev/null || true

# Wait for controller pods to terminate
for i in {1..30}; do
    if ! kubectl get pods -n "$CONTROLLER_NAMESPACE" 2>/dev/null | grep -q "arc-"; then
        echo "   Controller pods terminated."
        break
    fi
    echo "   Waiting for controller pods... ($i/30)"
    sleep 2
done

# Step 4: Remove CRDs (optional but recommended for clean upgrade)
echo ""
echo "📦 Step 4/5: Removing ARC CRDs..."
kubectl delete crd autoscalinglisteners.actions.github.com 2>/dev/null || true
kubectl delete crd autoscalingrunnersets.actions.github.com 2>/dev/null || true
kubectl delete crd ephemeralrunners.actions.github.com 2>/dev/null || true
kubectl delete crd ephemeralrunnersets.actions.github.com 2>/dev/null || true
echo "   CRDs removed."

# Step 5: Reinstall ARC
echo ""
echo "📦 Step 5/5: Reinstalling ARC..."

# Install controller
echo "   Installing ARC controller..."
helm install arc \
    --namespace "$CONTROLLER_NAMESPACE" \
    --create-namespace \
    --values "$ROOT_DIR/helm/controller-values.yaml" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# Wait for controller to be ready
echo "   Waiting for controller to be ready..."
kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=gha-rs-controller \
    -n "$CONTROLLER_NAMESPACE" \
    --timeout=120s

# Recreate namespace if needed
kubectl create namespace "$RUNNER_NAMESPACE" 2>/dev/null || true

# Check if secret exists, if not create it
if ! kubectl get secret pre-defined-secret -n "$RUNNER_NAMESPACE" &> /dev/null; then
    if [[ -f "$ROOT_DIR/secret.sh" ]]; then
        echo "   Creating secret from secret.sh..."
        bash "$ROOT_DIR/secret.sh"
    else
        echo "❌ secret.sh not found and secret doesn't exist!"
        echo "   Please create the secret manually or run deploy-arc.sh"
        exit 1
    fi
fi

# Install runner scale set
echo "   Installing runner scale set..."
helm install arc-runner-set \
    --namespace "$RUNNER_NAMESPACE" \
    --set githubConfigUrl="$GITHUB_CONFIG_URL" \
    --set githubConfigSecret=pre-defined-secret \
    --values "$ROOT_DIR/helm/values.yaml" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

echo ""
echo "✅ ARC upgrade complete!"
echo ""
echo "📊 Status:"
helm list -A
echo ""
kubectl get pods -n "$CONTROLLER_NAMESPACE"
echo ""
echo "🎉 ARC is back online. Queued jobs will now be picked up."

