#!/usr/bin/env bash
#
# AWS EC2 x86_64 installer wrapper for Outline Server.
#
# Defaults:
#   - Access keys: TCP/UDP 80 with POST%20 prefix
#   - Management API: TCP 443
#   - VPC/LAN targets: enabled
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Outline Server for AWS EC2 x86_64

Usage: sudo ./ec2/install.sh [options]

Defaults:
  --api-port 443
  --keys-port 80
  --prefix POST%20
  --lan-access

Options are forwarded to the shared installer:
  --hostname <elastic-ip-or-dns>
  --api-port <port>
  --keys-port <port>
  --prefix <url-encoded-prefix>
  --lan-access | --no-lan-access
  --lan-subnet <CIDR>
  --image <tag>
  --skip-build | --skip-deps
  -h, --help

Before installation, configure your EC2 security group:
  TCP 22  from your admin IP range
  TCP 443 from trusted Outline Manager admin IP ranges
  TCP 80 and UDP 80 from the client networks that will use the proxy
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root: sudo ./ec2/install.sh"
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ;;
  *) die "AWS EC2 x86_64 installer requires an x86_64 instance; found ${ARCH}." ;;
esac

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian|amzn) ;;
    *)
      die "Supported EC2 operating systems are Ubuntu, Debian, and Amazon Linux; found ${PRETTY_NAME:-unknown}."
      ;;
  esac
else
  die "Cannot identify the operating system: /etc/os-release is missing."
fi

ARGS=(
  --api-port 443
  --keys-port 80
  --prefix "POST%20"
  --lan-access
)

while (( $# > 0 )); do
  case "$1" in
    --hostname|--api-port|--keys-port|--prefix|--lan-subnet|--image)
      (( $# >= 2 )) || die "Missing value for $1"
      ARGS+=("$1" "$2")
      shift 2
      ;;
    --lan-access|--no-lan-access|--skip-build|--skip-deps)
      ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

log "AWS EC2 x86_64 Outline Server"
echo "    Architecture : ${ARCH}"
echo "    OS           : ${PRETTY_NAME:-unknown}"
echo "    Key defaults : port 80, prefix POST%20"
echo "    API default  : port 443"
echo "    VPC access   : enabled"

echo
echo "Security-group reminder: allow TCP/UDP 80 for clients and TCP 443 for trusted managers."
echo "Use an Elastic IP or stable DNS name with --hostname."

exec bash "${ROOT_DIR}/install.sh" "${ARGS[@]}"
