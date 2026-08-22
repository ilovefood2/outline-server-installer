#!/usr/bin/env bash
#
# Build an Outline Server (shadowbox) Docker image for the current host arch.
# On an x86_64 EC2 instance this produces linux/amd64; on a Raspberry Pi it
# produces linux/arm64.
#
# Usage:
#   ./scripts/build_image.sh
#   ./scripts/build_image.sh --tag localhost/outline/shadowbox:stable
#   ./scripts/build_image.sh --source-dir /path/to/outline-server
#   ./scripts/build_image.sh --version server-v1.12.3
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-localhost/outline/shadowbox:stable}"
SOURCE_DIR="${SOURCE_DIR:-}"
OUTLINE_VERSION="${OUTLINE_VERSION:-server-v1.12.3}"
OUTLINE_REPO="${OUTLINE_REPO:-https://github.com/OutlineFoundation/outline-server.git}"
CLEAN_CLONE=0
SKIP_NPM=0

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Build Outline Server Docker image for a supported native Linux architecture.

Options:
  --tag <name>          Image tag (default: ${IMAGE_TAG})
  --source-dir <path>   Existing outline-server checkout (skip clone)
  --version <tag>       Git tag/branch to clone (default: ${OUTLINE_VERSION}; patches must match)
  --repo <url>          Git remote (default: official OutlineFoundation repo)
  --clean               Remove previous clone under .build/ before cloning
  --skip-npm            Skip npm install if node_modules already present
  -h, --help            Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --tag) IMAGE_TAG="$2"; shift 2 ;;
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    --version) OUTLINE_VERSION="$2"; shift 2 ;;
    --repo) OUTLINE_REPO="$2"; shift 2 ;;
    --clean) CLEAN_CLONE=1; shift ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v docker >/dev/null || die "Docker is required. Install it first (./scripts/setup_docker.sh)."
command -v git >/dev/null || die "git is required."
command -v node >/dev/null || die "Node.js 18+ is required to build. See README."
command -v npm >/dev/null || die "npm is required."
command -v go >/dev/null || die "Go 1.21+ is required to build outline-ss-server."

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|aarch64|arm64) ;;
  *)
    die "Unsupported architecture: ${ARCH}. Use x86_64 or 64-bit ARM Linux."
    ;;
esac

# Normalize the host architecture for Docker and the upstream Taskfile. Go
# accepts arm64, not Linux's uname value aarch64.
case "${ARCH}" in
  aarch64|arm64)
    DOCKER_PLATFORM="linux/arm64"
    TASK_ARCH="arm64"
    ;;
  x86_64)
    DOCKER_PLATFORM="linux/amd64"
    TASK_ARCH="x86_64"
    ;;
esac

BUILD_ROOT="${ROOT_DIR}/.build"
mkdir -p "${BUILD_ROOT}"

if [[ -z "${SOURCE_DIR}" ]]; then
  SOURCE_DIR="${BUILD_ROOT}/outline-server"
  if (( CLEAN_CLONE )) && [[ -d "${SOURCE_DIR}" ]]; then
    log "Removing previous clone at ${SOURCE_DIR}"
    rm -rf "${SOURCE_DIR}"
  fi
  if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    log "Cloning ${OUTLINE_REPO} @ ${OUTLINE_VERSION}"
    git clone --depth 1 --branch "${OUTLINE_VERSION}" "${OUTLINE_REPO}" "${SOURCE_DIR}" \
      || git clone --depth 1 "${OUTLINE_REPO}" "${SOURCE_DIR}"
    # If branch/tag clone failed partially, check out tag if present
    if [[ -d "${SOURCE_DIR}/.git" ]]; then
      git -C "${SOURCE_DIR}" fetch --depth 1 origin "refs/tags/${OUTLINE_VERSION}:refs/tags/${OUTLINE_VERSION}" 2>/dev/null || true
      git -C "${SOURCE_DIR}" checkout "${OUTLINE_VERSION}" 2>/dev/null || true
    fi
  else
    log "Using existing clone at ${SOURCE_DIR}"
  fi
else
  [[ -d "${SOURCE_DIR}" ]] || die "Source dir not found: ${SOURCE_DIR}"
fi

[[ -f "${SOURCE_DIR}/Taskfile.yml" ]] || die "Not an outline-server tree: ${SOURCE_DIR}"

cd "${SOURCE_DIR}"

log "Applying project patches (access-key prefix and LAN targets)..."
bash "${ROOT_DIR}/scripts/apply_outline_patches.sh" "${SOURCE_DIR}"

# Ensure enough RAM on low-memory Pis by hinting Node
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=2048}"

if (( SKIP_NPM == 0 )) || [[ ! -d node_modules ]]; then
  log "Installing npm dependencies (this can take a while on a Pi)..."
  npm install --no-engine-strict
fi

# task binary is built by postinstall
TASK_BIN="${SOURCE_DIR}/node_modules/.bin/task"
if [[ ! -x "${TASK_BIN}" ]]; then
  # postinstall runs: go build github.com/go-task/task/v3/cmd/task -> ./task
  if [[ -x "${SOURCE_DIR}/task" ]]; then
    TASK_BIN="${SOURCE_DIR}/task"
  else
    die "Could not find go-task binary. Did npm install succeed?"
  fi
fi

log "Building shadowbox for ${ARCH} as ${TASK_ARCH} (${DOCKER_PLATFORM})..."
log "Image will be tagged: ${IMAGE_TAG}"

# Disable BuildKit if docker buildx is not available (e.g. Docker Desktop not configured)
if ! docker buildx version >/dev/null 2>&1; then
  export DOCKER_BUILDKIT=0
fi

# Taskfile uses TARGET_ARCH to derive Go's GOARCH, so it must receive arm64.
"${TASK_BIN}" shadowbox:docker:build \
  IMAGE_NAME="${IMAGE_TAG}" \
  IMAGE_VERSION="${OUTLINE_VERSION}" \
  TARGET_ARCH="${TASK_ARCH}"

log "Verifying image..."
docker image inspect "${IMAGE_TAG}" >/dev/null
docker images "${IMAGE_TAG}" --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.Architecture}}' 2>/dev/null \
  || docker images "${IMAGE_TAG}"

cat <<EOF

Build complete.

  Image:    ${IMAGE_TAG}
  Arch:     ${ARCH} → ${TASK_ARCH} (${DOCKER_PLATFORM})
  Source:   ${SOURCE_DIR}
  Version:  ${OUTLINE_VERSION}

Next step — install/run the server:

  sudo SB_IMAGE=${IMAGE_TAG} ./scripts/install_server.sh --hostname <YOUR_PUBLIC_IP_OR_DDNS>

Or use the all-in-one installer:

  sudo ./install.sh --hostname <YOUR_PUBLIC_IP_OR_DDNS>
EOF
