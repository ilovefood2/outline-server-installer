#!/usr/bin/env bash
#
# Install Node.js 18, Go, git, and build tools needed to compile Outline Server
# on Debian/Ubuntu or Amazon Linux, for arm64 or x86_64 hosts.
#
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root: sudo $0"
fi

PACKAGE_FAMILY=""
PACKAGE_MANAGER=""
if command -v apt-get >/dev/null 2>&1; then
  PACKAGE_FAMILY="deb"
  PACKAGE_MANAGER="apt-get"
  export DEBIAN_FRONTEND=noninteractive
elif command -v dnf >/dev/null 2>&1; then
  PACKAGE_FAMILY="rpm"
  PACKAGE_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PACKAGE_FAMILY="rpm"
  PACKAGE_MANAGER="yum"
else
  die "Unsupported package manager. Supported systems use apt-get, dnf, or yum."
fi

package_install() {
  if [[ "${PACKAGE_FAMILY}" == "deb" ]]; then
    apt-get install -y --no-install-recommends "$@"
  else
    "${PACKAGE_MANAGER}" install -y "$@"
  fi
}

if [[ "${PACKAGE_FAMILY}" == "deb" ]]; then
  log "Updating apt indexes..."
  apt-get update -y
else
  log "Refreshing ${PACKAGE_MANAGER} metadata..."
  "${PACKAGE_MANAGER}" makecache -y
fi

log "Installing base packages..."
if [[ "${PACKAGE_FAMILY}" == "deb" ]]; then
  package_install ca-certificates curl git build-essential python3 openssl gnupg
else
  # Amazon Linux 2023 includes curl-minimal and gnupg2-minimal by default.
  # Installing their full variants causes DNF to request a conflicting erase.
  package_install ca-certificates git gcc gcc-c++ make python3 openssl tar gzip
  if ! command -v curl >/dev/null 2>&1; then
    package_install curl-minimal
  fi
  if ! command -v gpg >/dev/null 2>&1 && ! command -v gpg2 >/dev/null 2>&1; then
    package_install gnupg2-minimal
  fi
fi

# --- Node.js 18 (NodeSource) ---
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
  if (( NODE_MAJOR >= 18 )); then
    log "Node.js already present: $(node -v)"
  else
    log "Node.js $(node -v) is too old; installing 18.x"
    if [[ "${PACKAGE_FAMILY}" == "deb" ]]; then
      curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    else
      curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
    fi
    package_install nodejs
  fi
else
  log "Installing Node.js 18.x..."
  if [[ "${PACKAGE_FAMILY}" == "deb" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  else
    curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
  fi
  package_install nodejs
fi

# --- Go ---
NEED_GO=1
if command -v go >/dev/null 2>&1; then
  # Accept Go 1.21+
  if go version | grep -Eq 'go1\.(2[1-9]|[3-9][0-9])'; then
    log "Go already present: $(go version)"
    NEED_GO=0
  fi
fi

if (( NEED_GO )); then
  ARCH="$(uname -m)"
  case "${ARCH}" in
    aarch64|arm64) GO_ARCH="arm64" ;;
    x86_64)        GO_ARCH="amd64" ;;
    *) die "Unsupported arch for Go install: ${ARCH}" ;;
  esac
  GO_VERSION="${GO_VERSION:-1.22.12}"
  log "Installing Go ${GO_VERSION} (${GO_ARCH})..."
  TMP="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "${TMP}/go.tgz"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${TMP}/go.tgz"
  rm -rf "${TMP}"
  ln -sfn /usr/local/go/bin/go /usr/local/bin/go
  ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi

# Ensure PATH for non-login shells
if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh
fi
export PATH="/usr/local/go/bin:${PATH}"

log "Versions:"
node -v
npm -v
go version
git --version

log "Build dependencies are ready."
