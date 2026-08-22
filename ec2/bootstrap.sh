#!/usr/bin/env bash
#
# Version-pinned HTTPS bootstrap for the AWS EC2 x86_64 installer.
#
# Run:
#   sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ilovefood2/outline-server-installer/v1.12.3-r2/ec2/bootstrap.sh)" -- --hostname <ELASTIC_IP_OR_DNS>
#
set -euo pipefail

REPOSITORY="ilovefood2/outline-server-installer"
RELEASE_REF="v1.12.3-r2"
ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/refs/tags/${RELEASE_REF}.tar.gz"
INSTALL_DIR="${OUTLINE_INSTALL_DIR:-/opt/outline-server-installer-${RELEASE_REF}}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Outline Server EC2 bootstrap (${RELEASE_REF})

Usage:
  sudo bash -c "\$(wget -qO- https://raw.githubusercontent.com/${REPOSITORY}/${RELEASE_REF}/ec2/bootstrap.sh)" -- --hostname <ELASTIC_IP_OR_DNS>

Arguments after -- are passed to ec2/install.sh.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run the bootstrap as root with sudo."
fi

if [[ -x "${INSTALL_DIR}/ec2/install.sh" ]]; then
  log "Using existing installer directory: ${INSTALL_DIR}"
  exec bash "${INSTALL_DIR}/ec2/install.sh" "$@"
fi

INSTALL_PARENT="$(dirname "${INSTALL_DIR}")"
mkdir -p "${INSTALL_PARENT}"
WORK_DIR="$(mktemp -d "${INSTALL_PARENT}/.outline-download.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
ARCHIVE_FILE="${WORK_DIR}/source.tar.gz"

log "Downloading ${REPOSITORY} ${RELEASE_REF}..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${ARCHIVE_URL}" -o "${ARCHIVE_FILE}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${ARCHIVE_FILE}" "${ARCHIVE_URL}"
else
  die "curl or wget is required to download the installer."
fi

tar -xzf "${ARCHIVE_FILE}" -C "${WORK_DIR}"
SOURCE_DIR="$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'outline-server-installer-*' -print -quit)"
[[ -n "${SOURCE_DIR}" ]] || die "Downloaded release did not contain an installer directory."
[[ -x "${SOURCE_DIR}/ec2/install.sh" ]] || die "Downloaded release is missing ec2/install.sh."

mv "${SOURCE_DIR}" "${INSTALL_DIR}"
log "Starting the EC2 installer from ${INSTALL_DIR}..."
exec bash "${INSTALL_DIR}/ec2/install.sh" "$@"
