#!/bin/bash
set -e

CLUSTER_NAME="arc-cluster"

echo "🚀 Creating Kubernetes cluster: $CLUSTER_NAME"

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "⏳ Docker not running. Starting Docker..."
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open -a Docker
    else
        sudo systemctl start docker
    fi
    
    echo "Waiting for Docker to start..."
    for i in {1..60}; do
        if docker info &> /dev/null; then
            echo "✅ Docker is ready!"
            break
        fi
        echo "  Waiting... ($i/60)"
        sleep 2
    done
    
    if ! docker info &> /dev/null; then
        echo "❌ Docker failed to start. Please start Docker manually."
        exit 1
    fi
fi

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "⚠️  Cluster '$CLUSTER_NAME' already exists."
    read -p "Delete and recreate? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kind delete cluster --name "$CLUSTER_NAME"
    else
        echo "Using existing cluster."
        kubectl config use-context "kind-$CLUSTER_NAME"
        exit 0
    fi
fi

# Create cluster
kind create cluster --name "$CLUSTER_NAME"

# Wait for node to be ready
echo "⏳ Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready node/${CLUSTER_NAME}-control-plane --timeout=120s

echo ""
echo "✅ Cluster '$CLUSTER_NAME' is ready!"
kubectl cluster-info --context "kind-$CLUSTER_NAME"

