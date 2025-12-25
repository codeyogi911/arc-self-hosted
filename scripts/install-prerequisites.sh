#!/bin/bash
set -e

echo "🔧 Installing ARC prerequisites..."

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    if ! command -v brew &> /dev/null; then
        echo "❌ Homebrew not found. Please install from https://brew.sh"
        exit 1
    fi

    echo "📦 Installing kubectl..."
    brew install kubectl 2>/dev/null || echo "kubectl already installed"

    echo "📦 Installing helm..."
    brew install helm 2>/dev/null || echo "helm already installed"

    echo "📦 Installing kind..."
    brew install kind 2>/dev/null || echo "kind already installed"

elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    echo "📦 Installing kubectl..."
    if ! command -v kubectl &> /dev/null; then
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi

    echo "📦 Installing helm..."
    if ! command -v helm &> /dev/null; then
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    echo "📦 Installing kind..."
    if ! command -v kind &> /dev/null; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
    fi
else
    echo "❌ Unsupported OS: $OSTYPE"
    exit 1
fi

echo ""
echo "✅ Prerequisites installed!"
echo ""
echo "Versions:"
kubectl version --client 2>/dev/null | head -1
helm version --short 2>/dev/null
kind version 2>/dev/null

