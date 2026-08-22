#!/usr/bin/env bash
#
# Show Outline Server status on this host.
#
set -euo pipefail

SHADOWBOX_DIR="${SHADOWBOX_DIR:-/opt/outline}"
CONTAINER_NAME="${CONTAINER_NAME:-shadowbox}"

echo "=== Host ==="
echo "Arch:    $(uname -m)"
echo "Kernel:  $(uname -r)"
echo "Host:    $(hostname)"
echo

echo "=== Docker containers ==="
if command -v docker >/dev/null 2>&1; then
  docker ps -a --filter "name=${CONTAINER_NAME}" --filter "name=watchtower" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
else
  echo "Docker not installed."
fi
echo

echo "=== Access config ==="
if [[ -f "${SHADOWBOX_DIR}/access.txt" ]]; then
  # Show apiUrl host/port only hints; full secrets still present for Manager paste
  cat "${SHADOWBOX_DIR}/access.txt"
  echo
  echo "Manager JSON (paste into Outline Manager → Set up Outline somewhere else):"
  API_URL="$(grep '^apiUrl:' "${SHADOWBOX_DIR}/access.txt" | cut -d: -f2-)"
  CERT="$(grep '^certSha256:' "${SHADOWBOX_DIR}/access.txt" | cut -d: -f2-)"
  printf '{"apiUrl":"%s","certSha256":"%s"}\n' "${API_URL}" "${CERT}"
else
  echo "No ${SHADOWBOX_DIR}/access.txt yet (server not installed?)."
fi
echo

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "=== Recent shadowbox logs ==="
  docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
fi

echo
echo "=== LAN access ==="
if [[ -f /etc/sysctl.d/99-outline-lan.conf ]]; then
  echo "Configured: yes"
  grep -v '^#' /etc/sysctl.d/99-outline-lan.conf | grep -v '^$' || true
  echo
  echo "Detected LAN subnets:"
  ip -o -4 addr show | awk '{print $2, $4}' | grep -vE '^(lo|docker|veth|br-)' || echo "  none"
else
  echo "Not configured. Run: sudo ./scripts/setup_lan_access.sh"
fi
