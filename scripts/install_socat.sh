#!/usr/bin/env bash
# Install socat on Debian/Ubuntu or Amazon Linux hosts.
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root: sudo $0"
fi

if command -v socat >/dev/null 2>&1; then
  log "socat already installed."
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y socat
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y socat
elif command -v yum >/dev/null 2>&1; then
  yum install -y socat
else
  die "Unsupported package manager. Install socat manually, then retry."
fi

log "socat installed."
