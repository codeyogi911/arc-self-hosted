#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RUNNER_VERSION_FILE="$ROOT_DIR/.runner-version"
RUNNER_IMAGE_REPOSITORY="${RUNNER_IMAGE_REPOSITORY:-ghcr.io/codeyogi911/arc-runner}"
COLIMA_PROFILE="${COLIMA_PROFILE:-arc}"
RUNNER_NAMESPACE="${RUNNER_NAMESPACE:-arc-runners}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build the minimal runner image directly in Colima's K3s image store.

Options:
  --check       Compare the pinned runner version with the latest upstream release
  --upgrade     Bump to the latest release, build it locally, and reload idle runners
  --pull-only   Pull the pinned image from GHCR instead of building it
  --no-reload   Do not update the deployed scale set after building or pulling
  -h, --help    Show this help

The multi-architecture GHCR image is published by
.github/workflows/rebuild-runner-image.yml. Local builds are native ARM64 and
are stored in the k8s.io containerd namespace, so K3s can use them immediately.

Pinned version: $(cat "$RUNNER_VERSION_FILE" 2>/dev/null || echo "unknown")
EOF
}

read_version() {
    tr -d '[:space:]' < "$RUNNER_VERSION_FILE"
}

write_version() {
    echo "$1" > "$RUNNER_VERSION_FILE"
}

get_upstream_version() {
    echo "🔍 Checking latest upstream runner version..." >&2
    curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' \
        | head -1
}

nerdctl_k8s() {
    colima nerdctl --profile "$COLIMA_PROFILE" -- --namespace k8s.io "$@"
}

ensure_runtime() {
    if ! colima status --profile "$COLIMA_PROFILE" &> /dev/null; then
        echo "❌ Colima profile '$COLIMA_PROFILE' is not running."
        echo "   Run ./scripts/create-cluster.sh first."
        exit 1
    fi
}

build_image() {
    local version="$1"
    echo "🔨 Building $RUNNER_IMAGE_REPOSITORY:$version natively on ARM64..."
    nerdctl_k8s build \
        --pull \
        --build-arg "RUNNER_VERSION=$version" \
        --tag "$RUNNER_IMAGE_REPOSITORY:$version" \
        --tag "$RUNNER_IMAGE_REPOSITORY:latest" \
        "$ROOT_DIR"
}

pull_image() {
    local version="$1"
    echo "📥 Pulling $RUNNER_IMAGE_REPOSITORY:$version into K3s..."
    nerdctl_k8s pull "$RUNNER_IMAGE_REPOSITORY:$version"
}

reload_runners() {
    local version="$1"
    if ! kubectl cluster-info &> /dev/null; then
        echo "⚠️  Kubernetes is not reachable; skipping runner reload."
        return
    fi

    local runner_set
    runner_set="$(kubectl get autoscalingrunnersets -n "$RUNNER_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$runner_set" ]]; then
        echo "ℹ️  No deployed runner scale set yet; the image is ready for deployment."
        return
    fi

    local image="$RUNNER_IMAGE_REPOSITORY:$version"
    echo "🔄 Updating runner scale set to use $image..."
    kubectl patch autoscalingrunnersets "$runner_set" \
        -n "$RUNNER_NAMESPACE" \
        --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$image\"}]"

    # Update templates already materialized by ARC. Existing runner pods are
    # deliberately left untouched: an apparently idle runner can receive a job
    # between inspection and deletion. Ephemeral runners retire naturally, and
    # all subsequently created runners use the new image.
    local ephemeral_runner_set
    while IFS= read -r ephemeral_runner_set; do
        [[ -z "$ephemeral_runner_set" ]] && continue
        kubectl patch ephemeralrunnersets "$ephemeral_runner_set" \
            -n "$RUNNER_NAMESPACE" \
            --type=json \
            -p="[{\"op\":\"replace\",\"path\":\"/spec/ephemeralRunnerSpec/spec/containers/0/image\",\"value\":\"$image\"}]"
    done < <(kubectl get ephemeralrunnersets -n "$RUNNER_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    echo "✅ Future runner pods will use $image; active runners were not interrupted."
}

CHECK=false
UPGRADE=false
PULL_ONLY=false
NO_RELOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK=true; shift ;;
        --upgrade) UPGRADE=true; shift ;;
        --pull-only) PULL_ONLY=true; shift ;;
        --no-reload) NO_RELOAD=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ ! -f "$RUNNER_VERSION_FILE" ]]; then
    echo "❌ Missing $RUNNER_VERSION_FILE"
    exit 1
fi

CURRENT_VERSION="$(read_version)"

if $CHECK || $UPGRADE; then
    UPSTREAM_VERSION="$(get_upstream_version)"
    if [[ -z "$UPSTREAM_VERSION" ]]; then
        echo "❌ Could not determine the latest upstream runner version."
        exit 1
    fi
fi

if $CHECK; then
    echo "Pinned version:   $CURRENT_VERSION"
    echo "Upstream version: $UPSTREAM_VERSION"
    [[ "$CURRENT_VERSION" == "$UPSTREAM_VERSION" ]] \
        && echo "✅ Runner image is up to date." \
        || echo "⚠️  A newer version is available. Run: $0 --upgrade"
    exit 0
fi

if $UPGRADE && [[ "$CURRENT_VERSION" != "$UPSTREAM_VERSION" ]]; then
    echo "⬆️  Upgrading runner version: $CURRENT_VERSION -> $UPSTREAM_VERSION"
    write_version "$UPSTREAM_VERSION"
    CURRENT_VERSION="$UPSTREAM_VERSION"
fi

ensure_runtime

if $PULL_ONLY; then
    pull_image "$CURRENT_VERSION"
else
    build_image "$CURRENT_VERSION"
fi

if ! $NO_RELOAD; then
    reload_runners "$CURRENT_VERSION"
fi

echo
echo "✅ Runner image ready: $RUNNER_IMAGE_REPOSITORY:$CURRENT_VERSION"
