#!/bin/bash
set -euo pipefail

echo "🔧 Installing ARC prerequisites..."

if [[ "$OSTYPE" != darwin* ]]; then
    echo "❌ This setup is tuned for Apple Silicon macOS and requires Homebrew."
    exit 1
fi

if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew not found. Install it from https://brew.sh"
    exit 1
fi

# Colima provides a lightweight Linux VM, containerd, and K3s directly. This
# replaces both Docker Desktop and the nested kind node container.
brew install colima kubectl helm

echo
echo "✅ Prerequisites installed."
echo
colima version
kubectl version --client
helm version --short
