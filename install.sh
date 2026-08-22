#!/usr/bin/env bash
#
# One-shot Outline Server installer for 64-bit Linux (ARM64 or x86_64).
#
# What this does:
#   1. Checks you are on a supported 64-bit ARM (or x86_64) host
#   2. Installs Docker if needed
#   3. Installs Node/Go build deps if a local image is missing
#   4. Builds localhost/outline/shadowbox:stable for your architecture
#   5. Runs the ARM-patched Outline install_server.sh
#
# Defaults: client key port 80, POST%20 prefix on every key, LAN access enabled.
#
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --hostname mypi.example.com --keys-port 443 --api-port 8443
#   sudo ./install.sh --skip-build          # if image already loaded
#   sudo ./install.sh --image my/registry/shadowbox:amd64
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

IMAGE_TAG="${SB_IMAGE:-localhost/outline/shadowbox:stable}"
SKIP_BUILD=0
SKIP_DEPS=0
LAN_ACCESS=1
LAN_SUBNET=""
HOSTNAME_FLAG=()
API_PORT_FLAG=()
KEYS_PORT_FLAG=(--keys-port 80)
PREFIX_FLAG=(--prefix "POST%20")
EXTRA_INSTALL_ARGS=()

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Outline Server for 64-bit Linux — installer

Usage: sudo ./install.sh [options]

Options:
  --hostname <host>   Public IP or DNS name clients will use
  --api-port <port>   Management API port (random if omitted)
  --keys-port <port>  Shadowsocks access-key port (default: 80)
  --prefix <value>    URL-encoded prefix for every access key (default: POST%20)
  --lan-access        Allow VPN clients to access the server's LAN (default)
  --no-lan-access     Keep the upstream public-IP-only target policy
  --lan-subnet <CIDR> Specify LAN subnet for --lan-access (auto-detected if omitted)
  --image <tag>       Docker image to run (default: ${IMAGE_TAG})
  --skip-build        Do not build; require --image or an existing local image
  --skip-deps         Do not install Node/Go (build must already be possible)
  -h, --help          Show help

Examples:
  sudo ./install.sh --hostname 203.0.113.10
  sudo ./install.sh --hostname vpn.home.arpa --keys-port 443 --api-port 8443
  sudo ./install.sh --hostname vpn.home.arpa --keys-port 80 --prefix POST%20
  sudo ./install.sh --skip-build --image localhost/outline/shadowbox:stable
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --hostname) HOSTNAME_FLAG=(--hostname "$2"); shift 2 ;;
    --api-port) API_PORT_FLAG=(--api-port "$2"); shift 2 ;;
    --keys-port) KEYS_PORT_FLAG=(--keys-port "$2"); shift 2 ;;
    --prefix)   PREFIX_FLAG=(--prefix "$2"); shift 2 ;;
    --lan-access) LAN_ACCESS=1; shift ;;
    --no-lan-access) LAN_ACCESS=0; shift ;;
    --lan-subnet) LAN_SUBNET="$2"; shift 2 ;;
    --image) IMAGE_TAG="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      # Forward unknown flags to install_server.sh
      EXTRA_INSTALL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  die "Please run as root: sudo ./install.sh"
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64|arm64|x86_64) ;;
  armv7l|armv6l)
    die "32-bit ARM (${ARCH}) is not supported. Flash 64-bit Raspberry Pi OS and re-run."
    ;;
  *)
    die "Unsupported architecture: ${ARCH}"
    ;;
esac

# Real-user home for build artifacts when invoked via sudo
REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 || echo /root)"

log "Outline Server"
echo "    Architecture : ${ARCH}"
echo "    Image        : ${IMAGE_TAG}"
echo "    Workdir      : ${SCRIPT_DIR}"
echo "    Key defaults : port ${KEYS_PORT_FLAG[1]}, prefix ${PREFIX_FLAG[1]}"
echo "    LAN access   : $([[ ${LAN_ACCESS} -eq 1 ]] && echo enabled || echo disabled)"

# --- Docker ---
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  log "Setting up Docker..."
  bash "${SCRIPT_DIR}/scripts/setup_docker.sh"
else
  log "Docker OK ($(docker --version))"
fi

# --- Image ---
have_image() {
  docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1
}

if have_image; then
  log "Using existing image ${IMAGE_TAG}"
elif (( SKIP_BUILD )); then
  log "Pulling ${IMAGE_TAG}..."
  docker pull "${IMAGE_TAG}" || die "Image ${IMAGE_TAG} not available. Build with ./scripts/build_image.sh or load a tarball."
else
  if (( SKIP_DEPS == 0 )); then
    log "Installing build dependencies (Node 18, Go, git)..."
    bash "${SCRIPT_DIR}/scripts/setup_build_deps.sh"
  fi

  # Low-memory safety for small ARM boards and EC2 instances with ≤2 GB RAM.
  TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if (( TOTAL_KB > 0 && TOTAL_KB < 3500000 )); then
    SWAP_TOTAL="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
    if (( SWAP_TOTAL < 1500000 )); then
      warn "Low RAM (${TOTAL_KB} kB). Ensuring ~2G swap for the build..."
      if [[ ! -f /swapfile.outline ]]; then
        fallocate -l 2G /swapfile.outline || dd if=/dev/zero of=/swapfile.outline bs=1M count=2048
        chmod 600 /swapfile.outline
        mkswap /swapfile.outline
      fi
      swapon /swapfile.outline 2>/dev/null || true
    fi
  fi

  log "Building Outline Server image (first run can take several minutes)..."
  # Run build as the real user when possible so files aren't all root-owned,
  # but docker needs group access — use root if user not in docker group yet.
  export PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"
  if [[ "${REAL_USER}" != "root" ]] && id -nG "${REAL_USER}" 2>/dev/null | grep -qw docker; then
    sudo -u "${REAL_USER}" -H \
      env PATH="/usr/local/go/bin:/usr/local/bin:${PATH}" \
          HOME="${REAL_HOME}" \
          IMAGE_TAG="${IMAGE_TAG}" \
      bash "${SCRIPT_DIR}/scripts/build_image.sh" --tag "${IMAGE_TAG}"
  else
    IMAGE_TAG="${IMAGE_TAG}" bash "${SCRIPT_DIR}/scripts/build_image.sh" --tag "${IMAGE_TAG}"
  fi
fi

have_image || die "Image ${IMAGE_TAG} still missing after build."

# --- Install / start ---
log "Installing and starting Outline Server..."
export SB_IMAGE="${IMAGE_TAG}"
# Disable Docker Content Trust — local images are unsigned
export DOCKER_CONTENT_TRUST=0
if (( LAN_ACCESS )); then
  export SB_ALLOW_PRIVATE_TARGETS=true
else
  export SB_ALLOW_PRIVATE_TARGETS=false
fi

bash "${SCRIPT_DIR}/scripts/install_server.sh" \
  "${HOSTNAME_FLAG[@]}" \
  "${API_PORT_FLAG[@]}" \
  "${KEYS_PORT_FLAG[@]}" \
  "${PREFIX_FLAG[@]}" \
  "${EXTRA_INSTALL_ARGS[@]}"

log "Done."

# ── LAN access ─────────────────────────────────────────────────────────────
if (( LAN_ACCESS )); then
  log "Configuring LAN access..."
  LAN_ARGS=()
  [[ -n "${LAN_SUBNET}" ]] && LAN_ARGS=(--lan-subnet "${LAN_SUBNET}")
  bash "${SCRIPT_DIR}/scripts/setup_lan_access.sh" "${LAN_ARGS[@]}"

  # Install socat for mobile client LAN proxying
  if ! command -v socat >/dev/null 2>&1; then
    log "Installing socat for mobile LAN proxy support..."
    bash "${SCRIPT_DIR}/scripts/install_socat.sh" || warn "Could not install socat automatically. Install it manually to use lan_proxy.sh."
  fi

  echo
  log "Client LAN access instructions:"
  bash "${SCRIPT_DIR}/scripts/client_lan_route.sh"
fi

echo
echo "Useful commands:"
echo "  sudo ./scripts/status.sh          # show API URL / Manager JSON"
echo "  sudo docker logs -f shadowbox     # follow server logs"
echo "  sudo ./scripts/uninstall.sh       # stop and remove containers"
if (( LAN_ACCESS )); then
  echo "  # LAN access is enabled. Verify or re-run later:"
  echo "  sudo ./scripts/setup_lan_access.sh --list"
fi
echo
echo "Download Outline Manager: https://getoutline.org/get-started/"
echo "Choose “Set up Outline somewhere else” and paste the JSON printed above."
