#!/usr/bin/env bash
#
# Stop and remove Outline Server containers and optional state on this host.
#
set -euo pipefail

SHADOWBOX_DIR="${SHADOWBOX_DIR:-/opt/outline}"
CONTAINER_NAME="${CONTAINER_NAME:-shadowbox}"
REMOVE_STATE=0
REMOVE_IMAGE=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Uninstall Outline Server containers from this machine.

Options:
  --remove-state   Also delete ${SHADOWBOX_DIR} (access keys, certs, config)
  --remove-image   Also remove localhost/outline/shadowbox images
  -h, --help       Show help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --remove-state) REMOVE_STATE=1; shift ;;
    --remove-image) REMOVE_IMAGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root: sudo $0"
fi

command -v docker >/dev/null || die "Docker not found."

for name in "${CONTAINER_NAME}" watchtower; do
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    log "Removing container ${name}..."
    docker rm -f "${name}" >/dev/null || true
  fi
done

if (( REMOVE_IMAGE )); then
  log "Removing local Outline images..."
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^localhost/outline/shadowbox' \
    | while read -r img; do docker rmi -f "${img}" || true; done
fi

if (( REMOVE_STATE )); then
  if [[ -d "${SHADOWBOX_DIR}" ]]; then
    log "Removing state directory ${SHADOWBOX_DIR}..."
    rm -rf "${SHADOWBOX_DIR}"
  fi
else
  log "Left state at ${SHADOWBOX_DIR} (pass --remove-state to delete)."
fi

log "Uninstall complete."
