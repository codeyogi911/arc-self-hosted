#!/bin/bash
set -e

echo "📦 Setting up OpenEBS for dynamic local storage provisioning..."
echo ""

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster."
    echo "   Run ./scripts/create-cluster.sh first."
    exit 1
fi

# Check if OpenEBS is already installed
if kubectl get storageclass openebs-hostpath &> /dev/null; then
    echo "✅ OpenEBS hostpath storage class already exists."
    kubectl get storageclass openebs-hostpath
    exit 0
fi

# Install OpenEBS dynamic LocalPV provisioner
echo "📥 Installing OpenEBS LocalPV provisioner..."
kubectl apply -f https://openebs.github.io/charts/openebs-operator-lite.yaml
kubectl apply -f https://openebs.github.io/charts/openebs-lite-sc.yaml

# Wait for OpenEBS pods to be ready
echo "⏳ Waiting for OpenEBS pods to be ready..."
kubectl wait --for=condition=Ready pod \
    -l name=openebs-localpv-provisioner \
    -n openebs \
    --timeout=120s 2>/dev/null || true

# Verify storage class
echo ""
echo "✅ OpenEBS setup complete!"
echo ""
echo "📊 Available storage classes:"
kubectl get storageclass
echo ""
echo "Use 'openebs-hostpath' as storageClassName in your values file."

