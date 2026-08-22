#!/usr/bin/env bash
#
# Raspberry Pi optimized Outline Server installer.
#
# Defaults:
#   - Keys port 80 (HTTP) — commonly unblocked on restrictive networks
#   - Prefix POST%20 — disguises Shadowsocks traffic as HTTP POST
#   - LAN access enabled — clients can reach the Pi's local network
#
# See: https://developer.getoutline.org/vpn/advanced/prefixing/
#
# Usage (on the Pi):
#   sudo ./raspberrypi/install.sh
#   sudo ./raspberrypi/install.sh --hostname mypi.example.com
#   sudo ./raspberrypi/install.sh --no-lan-access
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

log "Raspberry Pi Outline Server Installer"
echo "    Port 80 | HTTP POST prefix | LAN access enabled"

ARGS=(
  --keys-port 80
  --prefix "POST%20"
  --lan-access
)

while (( $# > 0 )); do
  case "$1" in
    --hostname)     ARGS+=(--hostname "$2"); shift 2 ;;
    --api-port)     ARGS+=(--api-port "$2"); shift 2 ;;
    --keys-port)    ARGS+=(--keys-port "$2"); shift 2 ;;
    --prefix)       ARGS+=(--prefix "$2"); shift 2 ;;
    --lan-access)   ARGS+=(--lan-access); shift ;;
    --no-lan-access) ARGS+=(--no-lan-access); shift ;;
    --lan-subnet)   ARGS+=(--lan-subnet "$2"); shift 2 ;;
    --image)        ARGS+=(--image "$2"); shift 2 ;;
    --skip-build)   ARGS+=(--skip-build); shift ;;
    --skip-deps)    ARGS+=(--skip-deps); shift ;;
    -h|--help)
      echo "Usage: sudo ./raspberrypi/install.sh [options]"
      echo ""
      echo "Raspberry Pi defaults:"
      echo "  --keys-port 80         HTTP port"
      echo "  --prefix POST%20       HTTP POST disguise"
      echo "  --lan-access           Enabled by default"
      echo ""
      echo "Override:"
      echo "  --no-lan-access        Disable automatic LAN access setup"
      echo "  --keys-port 443 --prefix %16%03%01"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage."
      exit 1
      ;;
  esac
done

exec bash "${PARENT_DIR}/install.sh" "${ARGS[@]}"
