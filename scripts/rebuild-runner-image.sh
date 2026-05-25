#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RUNNER_VERSION_FILE="$ROOT_DIR/.runner-version"
DOCKER_IMAGE="${DOCKER_IMAGE:-shashwatjain/arc-runner}"
KIND_CLUSTER="${KIND_CLUSTER:-arc-cluster}"
RUNNER_NAMESPACE="${RUNNER_NAMESPACE:-arc-runners}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Rebuild the custom runner image and deploy it to the local kind cluster.

Options:
  --check       Compare pinned version with latest upstream runner version
  --upgrade     Bump to latest upstream version if newer, then rebuild
  --load-only   Pull the pinned version from Docker Hub and load into kind
  --no-push     Build locally without pushing to Docker Hub
  --no-reload   Skip loading into kind and restarting runner pods
  -h, --help    Show this help

Version is pinned in .runner-version (currently: $(cat "$RUNNER_VERSION_FILE" 2>/dev/null || echo "unknown")).
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
    docker pull ghcr.io/actions/actions-runner:latest -q >&2
    docker run --rm ghcr.io/actions/actions-runner:latest \
        /home/runner/bin/Runner.Listener --version 2>&1 \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$'
}

build_image() {
    local version="$1"
    echo "🔨 Building $DOCKER_IMAGE:$version..."
    docker build \
        --build-arg "RUNNER_VERSION=$version" \
        -t "$DOCKER_IMAGE:$version" \
        -t "$DOCKER_IMAGE:latest" \
        "$ROOT_DIR"
}

push_image() {
    local version="$1"
    echo "📤 Pushing $DOCKER_IMAGE:$version and :latest..."
    docker push "$DOCKER_IMAGE:$version"
    docker push "$DOCKER_IMAGE:latest"
}

load_into_kind() {
    local version="$1"
    if ! command -v kind &> /dev/null; then
        echo "⚠️  kind not found, skipping cluster load."
        return
    fi
    if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
        echo "⚠️  kind cluster '$KIND_CLUSTER' not found, skipping cluster load."
        return
    fi

    echo "📦 Loading image into kind cluster '$KIND_CLUSTER'..."
    kind load docker-image "$DOCKER_IMAGE:$version" --name "$KIND_CLUSTER"
    kind load docker-image "$DOCKER_IMAGE:latest" --name "$KIND_CLUSTER"
}

reload_runners() {
    local version="$1"
    if ! kubectl cluster-info &> /dev/null; then
        echo "⚠️  Kubernetes cluster not reachable, skipping runner reload."
        return
    fi

    local runner_set
    runner_set="$(kubectl get autoscalingrunnersets -n "$RUNNER_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$runner_set" ]]; then
        echo "⚠️  No AutoscalingRunnerSet found in $RUNNER_NAMESPACE, skipping runner reload."
        return
    fi

    echo "🔄 Updating runner scale set to use $DOCKER_IMAGE:$version..."
    kubectl patch autoscalingrunnersets "$runner_set" \
        -n "$RUNNER_NAMESPACE" \
        --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$DOCKER_IMAGE:$version\"}]"

    echo "🧹 Restarting runner pods..."
    kubectl delete pods -n "$RUNNER_NAMESPACE" -l actions.github.com/scale-set-name=arc-runner-set --ignore-not-found
}

CHECK=false
UPGRADE=false
LOAD_ONLY=false
NO_PUSH=false
NO_RELOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK=true; shift ;;
        --upgrade) UPGRADE=true; shift ;;
        --load-only) LOAD_ONLY=true; shift ;;
        --no-push) NO_PUSH=true; shift ;;
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

if $CHECK || $UPGRADE || ! $LOAD_ONLY; then
    UPSTREAM_VERSION="$(get_upstream_version)"
fi

if $CHECK; then
    echo "Pinned version:   $CURRENT_VERSION"
    echo "Upstream version: $UPSTREAM_VERSION"
    if [[ "$CURRENT_VERSION" == "$UPSTREAM_VERSION" ]]; then
        echo "✅ Runner image is up to date."
    else
        echo "⚠️  A newer runner version is available. Run: ./scripts/rebuild-runner-image.sh --upgrade"
    fi
    exit 0
fi

if $UPGRADE; then
    if [[ "$CURRENT_VERSION" == "$UPSTREAM_VERSION" ]]; then
        echo "✅ Already on latest runner version ($CURRENT_VERSION)."
    else
        echo "⬆️  Upgrading runner version: $CURRENT_VERSION -> $UPSTREAM_VERSION"
        write_version "$UPSTREAM_VERSION"
        CURRENT_VERSION="$UPSTREAM_VERSION"
    fi
fi

if $LOAD_ONLY; then
    echo "📥 Pulling $DOCKER_IMAGE:$CURRENT_VERSION..."
    docker pull "$DOCKER_IMAGE:$CURRENT_VERSION"
    load_into_kind "$CURRENT_VERSION"
    if ! $NO_RELOAD; then
        reload_runners "$CURRENT_VERSION"
    fi
    echo "✅ Loaded $DOCKER_IMAGE:$CURRENT_VERSION into kind."
    exit 0
fi

build_image "$CURRENT_VERSION"

if ! $NO_PUSH; then
    push_image "$CURRENT_VERSION"
fi

load_into_kind "$CURRENT_VERSION"

if ! $NO_RELOAD; then
    reload_runners "$CURRENT_VERSION"
fi

echo ""
echo "✅ Runner image ready: $DOCKER_IMAGE:$CURRENT_VERSION"
