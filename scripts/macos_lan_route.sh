#!/usr/bin/env bash
#
# Keep a route to the Pi's LAN alive on macOS.
# Run once; survives Outline reconnects by watching for the utun interface.
#
# Usage:
#   ./scripts/macos_lan_route.sh               # auto-detect subnet + start watcher
#   ./scripts/macos_lan_route.sh 10.0.0.0/24   # explicit subnet
#
set -euo pipefail

SUBNET="${1:-}"

if [[ -z "${SUBNET}" ]]; then
  SUBNET="10.0.0.0/24"
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script is for macOS only."
  echo "For Linux use: sudo ip route add ${SUBNET} dev tun0"
  echo "For Windows: route add ${SUBNET} mask 255.255.255.0 <pi_ip>"
  exit 1
fi

add_route() {
  local iface
  iface="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $4~/utun/ {print $4; exit}')"
  if [[ -z "${iface}" ]]; then
    return 1
  fi
  if netstat -rn -f inet | grep -q "${SUBNET}.*${iface}"; then
    return 0
  fi
  sudo route add -net "${SUBNET}" -interface "${iface}" 2>/dev/null && \
    echo "[$(date +%H:%M:%S)] Route added: ${SUBNET} → ${iface}"
}

echo "Watching for Outline VPN interface (utun) to add route for ${SUBNET}..."
echo "Leave this running. Ctrl+C to stop."
echo

# Add route immediately if interface is already up
add_route || true

# Watch for changes every 5 seconds
while true; do
  sleep 5
  add_route || true
done
