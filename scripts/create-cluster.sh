#!/bin/bash
set -euo pipefail

COLIMA_PROFILE="${COLIMA_PROFILE:-arc}"
COLIMA_CPU="${COLIMA_CPU:-12}"
COLIMA_MEMORY="${COLIMA_MEMORY:-24}"
COLIMA_DISK="${COLIMA_DISK:-150}"
KUBE_CONTEXT="colima-${COLIMA_PROFILE}"

if [[ "$OSTYPE" != darwin* ]]; then
    echo "❌ This profile is tuned for Apple Silicon macOS."
    exit 1
fi

for command in colima kubectl; do
    if ! command -v "$command" &> /dev/null; then
        echo "❌ $command is not installed. Run ./scripts/install-prerequisites.sh first."
        exit 1
    fi
done

echo "🚀 Starting Colima/K3s profile: $COLIMA_PROFILE"
echo "   Runtime: containerd"
echo "   VM: Apple Virtualization.framework (vz)"
echo "   Resources: ${COLIMA_CPU} CPU, ${COLIMA_MEMORY} GiB RAM, ${COLIMA_DISK} GiB disk"

# Colima updates CPU and memory on an existing stopped profile. Runtime and VM
# type are immutable after creation, which keeps this command idempotent.
colima start \
    --profile "$COLIMA_PROFILE" \
    --vm-type vz \
    --runtime containerd \
    --kubernetes \
    --k3s-arg '--disable=traefik' \
    --k3s-arg '"--kubelet-arg=kube-reserved=cpu=500m,memory=1Gi"' \
    --k3s-arg '"--kubelet-arg=system-reserved=cpu=500m,memory=1Gi"' \
    --cpus "$COLIMA_CPU" \
    --memory "$COLIMA_MEMORY" \
    --disk "$COLIMA_DISK"

kubectl config use-context "$KUBE_CONTEXT" > /dev/null

echo "⏳ Waiting for K3s to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s

echo
echo "✅ Colima/K3s is ready."
kubectl cluster-info
kubectl get nodes -o wide
