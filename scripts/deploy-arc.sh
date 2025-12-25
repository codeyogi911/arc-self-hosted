#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONTROLLER_NAMESPACE="arc-systems"
RUNNER_NAMESPACE="arc-runners"

# GitHub Config URL - set this to your organization or repository
# Examples:
#   Organization: https://github.com/my-org
#   Repository:   https://github.com/my-org/my-repo
GITHUB_CONFIG_URL="${GITHUB_CONFIG_URL:-}"

if [[ -z "$GITHUB_CONFIG_URL" ]]; then
    echo "❌ GITHUB_CONFIG_URL is not set!"
    echo ""
    echo "Set it before running this script:"
    echo "  export GITHUB_CONFIG_URL=https://github.com/YOUR_ORG"
    echo ""
    echo "Or for a specific repository:"
    echo "  export GITHUB_CONFIG_URL=https://github.com/YOUR_ORG/YOUR_REPO"
    exit 1
fi

echo "🚀 Deploying Actions Runner Controller..."

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster."
    echo "   Run ./scripts/create-cluster.sh first."
    exit 1
fi

# Step 1: Install ARC Controller
echo ""
echo "📦 Installing ARC Controller in namespace: $CONTROLLER_NAMESPACE"
helm upgrade --install arc \
    --namespace "$CONTROLLER_NAMESPACE" \
    --create-namespace \
    --values "$ROOT_DIR/helm/controller-values.yaml" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# Wait for controller to be ready
echo "⏳ Waiting for controller to be ready..."
kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=gha-rs-controller \
    -n "$CONTROLLER_NAMESPACE" \
    --timeout=120s

# Step 2: Create runner namespace and secret
echo ""
echo "🔐 Setting up runner namespace and secret..."
kubectl create namespace "$RUNNER_NAMESPACE" 2>/dev/null || true

# Check if secret exists
if kubectl get secret pre-defined-secret -n "$RUNNER_NAMESPACE" &> /dev/null; then
    echo "   Secret 'pre-defined-secret' already exists."
else
    if [[ -f "$ROOT_DIR/secret.sh" ]]; then
        echo "   Creating secret from secret.sh..."
        bash "$ROOT_DIR/secret.sh"
    else
        echo "❌ secret.sh not found!"
        echo "   Copy secret.template.sh to secret.sh and configure your GitHub App credentials."
        exit 1
    fi
fi

# Step 3: Install Runner Scale Set
echo ""
echo "📦 Installing Runner Scale Set..."
helm upgrade --install arc-runner-set \
    --namespace "$RUNNER_NAMESPACE" \
    --set githubConfigUrl="$GITHUB_CONFIG_URL" \
    --set githubConfigSecret=pre-defined-secret \
    --values "$ROOT_DIR/helm/runner-scale-set-values.yaml" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

echo ""
echo "✅ ARC deployment complete!"
echo ""
echo "📊 Status:"
helm list -A
echo ""
kubectl get pods -n "$CONTROLLER_NAMESPACE"
echo ""
echo "🎉 Use 'runs-on: arc-runner-set' in your workflows!"

