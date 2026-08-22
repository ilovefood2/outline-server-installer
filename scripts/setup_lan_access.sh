#!/usr/bin/env bash
#
# Configure the Raspberry Pi so that Outline clients connected through this
# server can reach devices on the same LAN (local network) as the Pi.
#
# IMPORTANT: ping/ICMP will NOT work — Outline only proxies TCP and UDP.
#            Use curl, nc, or a browser to test TCP connectivity instead.
#
# This project builds Shadowbox with private-target support and runs it with
# --net host, so authenticated clients can reach LAN destinations that the Pi
# itself can route to. Upstream Shadowbox blocks private destinations.
#
# This script handles the edge case of UDP return traffic, which can be
# dropped by strict reverse-path filtering (rp_filter) on some kernels.
#
# Usage:
#   sudo ./scripts/setup_lan_access.sh
#   sudo ./scripts/setup_lan_access.sh --lan-subnet 192.168.1.0/24
#
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

LAN_SUBNET=""
LIST_SUBNETS=0

while (( $# > 0 )); do
  case "$1" in
    --lan-subnet) LAN_SUBNET="$2"; shift 2 ;;
    --list) LIST_SUBNETS=1; shift ;;
    --skip-iptables) shift ;; # retained as a compatibility no-op
    -h|--help)
      echo "Usage: setup_lan_access.sh [--lan-subnet <CIDR>] [--list]"
      echo ""
      echo "TCP proxying to LAN devices works automatically since the Outline"
      echo "server runs with host networking.  This script only handles UDP"
      echo "edge cases via rp_filter tuning."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if (( EUID != 0 )); then
  echo "ERROR: Run as root: sudo $0" >&2
  exit 1
fi

detect_subnets() {
  for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-)'); do
    ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' || true
  done
}

if (( LIST_SUBNETS )); then
  log "Detected LAN subnets:"
  detect_subnets
  exit 0
fi

to_network_addr() {
  local ip="${1%/*}" mask="${1#*/}" OLDIFS="$IFS"
  local -a o n
  IFS=. read -ra o <<< "$ip"
  IFS="$OLDIFS"
  local -i m=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
  for i in 0 1 2 3; do
    n[i]=$(( o[i] & ((m >> (24 - 8*i)) & 0xFF) ))
  done
  echo "$(IFS=.; echo "${n[*]}")/${mask}"
}

if [[ -z "${LAN_SUBNET}" ]]; then
  RAW="$(detect_subnets | head -1)"
  if [[ -z "${RAW}" ]]; then
    LAN_SUBNET="192.168.0.0/16"
    log "Could not auto-detect; defaulting to ${LAN_SUBNET}"
  else
    LAN_SUBNET="$(to_network_addr "${RAW}")"
    log "Detected LAN subnet: ${RAW} -> ${LAN_SUBNET}"
  fi
fi

# ── rp_filter: loose mode for UDP return traffic ────────────────────────────

SYSCTL_CONF="/etc/sysctl.d/99-outline-lan.conf"

log "Setting rp_filter to loose mode (prevents UDP return drops)..."
cat > "${SYSCTL_CONF}" <<EOF
# Outline Server — loose rp_filter so UDP return traffic from LAN is not dropped
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF

sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
for iface in $(ls /proc/sys/net/ipv4/conf/ 2>/dev/null); do
  sysctl -w "net.ipv4.conf.${iface}.rp_filter=2" >/dev/null 2>&1 || true
done

# Shadowbox opens ordinary host TCP/UDP sockets to LAN destinations. It does
# not forward IP packets between interfaces, so FORWARD/NAT rules are neither
# required nor desirable here.
log "No iptables forwarding rules are required for ${LAN_SUBNET}."

# ── Diagnostic ──────────────────────────────────────────────────────────────

log "Running diagnostics..."

# Can the Pi itself route to its default LAN gateway?
LAN_TEST_HOST="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
echo -n "  Pi → LAN route       : "
if [[ -n "${LAN_TEST_HOST}" ]] && ip -4 route get "${LAN_TEST_HOST}" >/dev/null 2>&1; then
  echo "OK"
else
  echo "FAIL (no reachable IPv4 default gateway)"
fi

# Did the patched proxy start with private targets enabled?
echo -n "  Shadowbox LAN policy : "
SHADOWBOX_LOGS="$(docker logs shadowbox 2>&1 || true)"
if [[ "${SHADOWBOX_LOGS}" == *"--allow_private_targets"* ]]; then
  echo "OK"
else
  echo "FAIL (rebuild/reinstall the project image)"
fi

echo
echo "LAN access configured."
echo
echo "IMPORTANT: Ping will NOT work through Outline — only TCP and UDP are proxied."
echo "Test a known LAN service through the connected client, for example:"
echo "  curl --connect-timeout 3 http://<LAN_DEVICE_IP>"
echo ""
echo "If TCP doesn't work, check that your Outline Client routes private IPs"
echo "through the proxy (not bypassing them). This is a client-side setting."
