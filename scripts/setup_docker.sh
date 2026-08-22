#!/usr/bin/env bash
#
# Install and enable Docker on Debian/Ubuntu or Amazon Linux.
#
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root: sudo $0"
fi

if command -v docker >/dev/null 2>&1; then
  log "Docker already installed: $(docker --version)"
else
  OS_ID=""
  OS_VERSION=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
  fi
  if [[ "${OS_ID}" == "amzn" ]]; then
    if [[ "${OS_VERSION}" == "2" ]] && command -v amazon-linux-extras >/dev/null 2>&1; then
      log "Installing Docker from Amazon Linux Extras..."
      amazon-linux-extras install -y docker
    elif command -v dnf >/dev/null 2>&1; then
      log "Installing Docker from Amazon Linux packages..."
      dnf install -y docker
    elif command -v yum >/dev/null 2>&1; then
      log "Installing Docker from Amazon Linux packages..."
      yum install -y docker
    else
      die "Could not find dnf or yum on Amazon Linux."
    fi
  else
    log "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
  fi
fi

systemctl enable --now docker.service

# Allow invoking user (if sudo) to use docker without root next time
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER}" || true
  log "Added ${SUDO_USER} to the docker group (log out/in for it to apply)."
fi

docker info >/dev/null
log "Docker is ready."
