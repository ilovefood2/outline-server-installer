#!/usr/bin/env bash
#
# Port-forward a LAN device through the Pi so it's reachable through Outline
# on clients that can't add custom routes (iOS, Android).
#
# The Pi is always reachable through the VPN.  This script uses socat to
# relay connections from the Pi to another LAN device.
#
# Usage:
#   sudo ./scripts/lan_proxy.sh add    <port> <lan_ip:port>
#   sudo ./scripts/lan_proxy.sh remove <port>
#   sudo ./scripts/lan_proxy.sh list
#   sudo ./scripts/lan_proxy.sh install        # install socat + persist as service
#
# Example:
#   sudo ./scripts/lan_proxy.sh add 8080 10.0.0.1:80
#   # Now clients can reach the router at http://<pi-ip>:8080
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

CMD="${1:-}"

usage() {
  cat <<EOF
Usage: lan_proxy.sh <command>

Commands:
  install             Install dependencies
  add    <port> <lan_ip:port>   Start forwarding (socat, good for HTTP)
  add-nat <port> <lan_ip:port>  Start forwarding (iptables, good for RDP)
  remove <port>                 Stop forwarding
  list                          Show active proxies
  save                          Persist iptables rules across reboots

Examples:
  # HTTP services (socat works fine):
  sudo ./scripts/lan_proxy.sh add 8080 10.0.0.1:80

  # RDP/SSH/games (iptables for transparency):
  sudo ./scripts/lan_proxy.sh add-nat 3389 10.0.0.175:3389
  sudo ./scripts/lan_proxy.sh save

  # Now RDP to <pi-ip>:3389 from any client — no route needed
EOF
}

case "${CMD}" in
  install)
    if (( EUID != 0 )); then die "Run as root: sudo $0 install"; fi
    log "Installing socat..."
    bash "${SCRIPT_DIR}/install_socat.sh"
    echo "Now add proxies: sudo $0 add <local_port> <lan_ip:lan_port>"
    ;;

  add)
    if (( EUID != 0 )); then die "Run as root: sudo $0 add ..."; fi
    LOCAL_PORT="${2:-}"; TARGET="${3:-}"
    [[ -n "${LOCAL_PORT}" && -n "${TARGET}" ]] || die "Usage: $0 add <local_port> <lan_ip:port>"
    if pgrep -f "socat.*TCP-LISTEN:${LOCAL_PORT}" >/dev/null; then
      die "Port ${LOCAL_PORT} already has a proxy running. Remove it first: $0 remove ${LOCAL_PORT}"
    fi
    nohup socat TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:${TARGET} >/dev/null 2>&1 &
    echo "Proxy started: <pi-ip>:${LOCAL_PORT} → ${TARGET}  (PID $!)"
    echo "Clients connect to: <pi-ip>:${LOCAL_PORT}"
    ;;

  add-nat)
    if (( EUID != 0 )); then die "Run as root: sudo $0 add-nat ..."; fi
    LOCAL_PORT="${2:-}"; TARGET="${3:-}"
    [[ -n "${LOCAL_PORT}" && -n "${TARGET}" ]] || die "Usage: $0 add-nat <local_port> <lan_ip:port>"
    if iptables -t nat -C PREROUTING -p tcp --dport "${LOCAL_PORT}" -j DNAT --to-destination "${TARGET}" 2>/dev/null; then
      die "Port ${LOCAL_PORT} already has a NAT rule."
    fi
    iptables -t nat -A PREROUTING -p tcp --dport "${LOCAL_PORT}" -j DNAT --to-destination "${TARGET}"
    iptables -t nat -A POSTROUTING -p tcp -d "${TARGET%:*}" --dport "${TARGET#*:}" -j MASQUERADE
    echo "NAT rule added: <pi-ip>:${LOCAL_PORT} → ${TARGET}"
    echo "Use '$0 save' to persist across reboots."
    ;;

  remove)
    if (( EUID != 0 )); then die "Run as root: sudo $0 remove ..."; fi
    PORT="${2:-}"; [[ -n "${PORT}" ]] || die "Usage: $0 remove <port>"
    # Try socat first
    PID="$(pgrep -f "socat.*TCP-LISTEN:${PORT}" 2>/dev/null || true)"
    if [[ -n "${PID}" ]]; then
      kill "${PID}" 2>/dev/null || true
    fi
    # Then iptables
    if iptables -t nat -C PREROUTING -p tcp --dport "${PORT}" -j DNAT 2>/dev/null; then
      iptables -t nat -D PREROUTING -p tcp --dport "${PORT}" -j DNAT
      echo "NAT rule on port ${PORT} removed."
    elif [[ -n "${PID}" ]]; then
      echo "Proxy on port ${PORT} stopped."
    else
      echo "No proxy on port ${PORT}."
    fi
    ;;

  save)
    if (( EUID != 0 )); then die "Run as root: sudo $0 save"; fi
    mkdir -p /etc/iptables
    if command -v iptables-save >/dev/null 2>&1; then
      iptables-save > /etc/iptables/rules.v4
      log "iptables rules saved to /etc/iptables/rules.v4"
    fi
    # Debian/Ubuntu can restore this file automatically with iptables-persistent.
    # Amazon Linux has no equivalent package configured by this project.
    if command -v apt-get >/dev/null 2>&1 && ! dpkg -s iptables-persistent >/dev/null 2>&1; then
      echo "Installing iptables-persistent for automatic restore on boot..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    elif ! command -v apt-get >/dev/null 2>&1; then
      echo "Rules were saved, but configure an OS-specific restore service for persistence after reboot."
    fi
    ;;

  list)
    echo "Active LAN proxies:"
    echo "  [socat]"
    if ps aux 2>/dev/null | grep -q '[s]ocat.*TCP-LISTEN'; then
      ps aux 2>/dev/null | grep '[s]ocat.*TCP-LISTEN' | while read -r line; do
        echo "    $line" | sed 's/.*socat //'
      done
    else
      echo "    none"
    fi
    echo "  [iptables NAT]"
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep -E 'DNAT.*dpt:[0-9]' | sed 's/^/    /' || echo "    none"
    ;;

  *)
    usage
    ;;
esac
