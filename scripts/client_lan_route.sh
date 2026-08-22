#!/usr/bin/env bash
#
# Print the commands a client device needs to run to access the Pi's LAN
# through Outline.  The Outline server proxy can already reach LAN devices
# (it runs with --net host on the Pi).  The problem is that every OS
# excludes private IP ranges from VPN tunnels by default.
#
# Usage:
#   ./scripts/client_lan_route.sh
#   ./scripts/client_lan_route.sh --subnet 10.0.0.0/24
#
set -euo pipefail

SUBNET="${1:-}"

to_network() {
  local ip="${1%/*}" mask="${1#*/}" OLDIFS="$IFS"
  local -a octets net
  IFS=. read -ra octets <<< "$ip"
  IFS="$OLDIFS"
  local -i m=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
  local -i i
  for i in 0 1 2 3; do
    net[i]=$(( octets[i] & ((m >> (24 - 8*i)) & 0xFF) ))
  done
  echo "$(IFS=.; echo "${net[*]}")/${mask}"
}

if [[ -z "${SUBNET}" ]]; then
  RAW="$(ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(lo|docker|veth|br-)/ {print $4}' | head -1)"
  if [[ -n "${RAW}" ]]; then
    SUBNET="$(to_network "${RAW}")"
  else
    SUBNET="10.0.0.0/24"
  fi
fi

case "${1:-}" in
  -h|--help)
    echo "Usage: client_lan_route.sh [<CIDR>]"
    echo ""
    echo "Prints the commands needed on each client platform to route the"
    echo "Pi's LAN subnet through the Outline VPN tunnel."
    echo ""
    echo "Why: Outline clients exclude private IPs from VPN routing by default."
    exit 0
    ;;
esac

PI_IP="$(ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(lo|docker|veth|br-)/ {gsub(/\/.*/,"",$4); print $4}' | head -1)"
PI_IP="${PI_IP:-<PI_LAN_IP>}"

echo
echo "======================================================================"
echo "  Client-side commands to access Pi's LAN (${SUBNET}) through Outline"
echo "======================================================================"
echo
echo "IMPORTANT: These must be run on each CLIENT device, not the Pi."
echo "The Outline proxy can already reach the LAN — the issue is the client"
echo "OS excludes private IPs from the VPN tunnel."
echo

cat <<'PLATFORM_EOF'

── macOS ──────────────────────────────────────────────────────────────

# Find the Outline VPN interface (the utun carrying the default route):
OUTLINE_IF="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $4~/utun/ {print $4; exit}')"
echo "Outline interface: ${OUTLINE_IF:-NOT FOUND}"

# If not found, list all utun interfaces and pick the last one:
if [ -z "${OUTLINE_IF}" ]; then
  OUTLINE_IF="$(ifconfig 2>/dev/null | grep '^utun' | tail -1 | cut -d: -f1)"
fi

PLATFORM_EOF

echo "# Add route (one-time, survives until reboot/disconnect):"
echo "sudo route add -net ${SUBNET} -interface \"\${OUTLINE_IF}\""
echo
echo "# Test:"
echo "curl --connect-timeout 3 http://${PI_IP}"
echo "curl --connect-timeout 3 http://<LAN_DEVICE_IP>"

cat <<'PLATFORM_EOF'

── Windows (PowerShell, as Admin) ─────────────────────────────────────

# Find Outline interface index:
Get-NetAdapter | Select Name, InterfaceIndex

PLATFORM_EOF

echo "# Add route (replace <INDEX> with the Outline adapter's InterfaceIndex):"
echo "New-NetRoute -DestinationPrefix '${SUBNET}' -InterfaceIndex <INDEX> -NextHop 0.0.0.0"

echo "# Test:"
echo "curl http://<LAN_DEVICE_IP> --connect-timeout 3"
echo

cat <<'PLATFORM_EOF'
── Linux ──────────────────────────────────────────────────────────────
PLATFORM_EOF

echo
echo "# Add route (Outline creates a tun interface, usually tun0):"
echo "sudo ip route add ${SUBNET} dev tun0"
echo
echo "# Test:"
echo "curl --connect-timeout 3 http://<LAN_DEVICE_IP>"

echo
echo "── Android / iOS ───────────────────────────────────────────────────────"
echo
echo "Mobile clients can't add custom routes. Instead, port-forward through the Pi:"
echo
echo "  # On the Pi, install socat and proxy a LAN service:"
echo "  sudo ./scripts/lan_proxy.sh install"
echo "  sudo ./scripts/lan_proxy.sh add 8080 10.0.0.1:80"
echo "  # Now connect to http://${PI_IP}:8080 from any Outline client"
echo
echo "  # List active proxies:"
echo "  sudo ./scripts/lan_proxy.sh list"
echo
echo "The Pi is always reachable through the VPN since it IS the server."
echo "======================================================================"
