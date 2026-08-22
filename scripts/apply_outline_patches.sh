#!/usr/bin/env bash
#
# Apply this project's Outline Server and outline-ss-server patches to a
# server-v1.12.3 source checkout. Safe to run repeatedly.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${1:-}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "${SOURCE_DIR}" ]] || die "Usage: $0 <outline-server-source-dir>"
[[ -d "${SOURCE_DIR}" ]] || die "Source directory not found: ${SOURCE_DIR}"
SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"
[[ -f "${SOURCE_DIR}/go.mod" ]] || die "Not an Outline Server source tree: ${SOURCE_DIR}"

command -v git >/dev/null 2>&1 || die "git is required to apply source patches."
command -v go >/dev/null 2>&1 || die "Go is required to vendor outline-ss-server."

apply_idempotent_patch() {
  local patch_file="$1"
  if git -C "${SOURCE_DIR}" apply --check "${patch_file}" 2>/dev/null; then
    git -C "${SOURCE_DIR}" apply "${patch_file}"
    log "Applied $(basename "${patch_file}")"
  elif git -C "${SOURCE_DIR}" apply --reverse --check "${patch_file}" 2>/dev/null; then
    log "Already applied: $(basename "${patch_file}")"
  else
    die "Patch does not apply cleanly: ${patch_file}. Use Outline Server server-v1.12.3 or update the patch."
  fi
}

SERVER_PATCH="${ROOT_DIR}/patches/outline-server-v1.12.3.patch"
SS_SERVER_PATCH="${ROOT_DIR}/patches/outline-ss-server-v1.7.3.patch"
[[ -f "${SERVER_PATCH}" ]] || die "Missing patch: ${SERVER_PATCH}"
[[ -f "${SS_SERVER_PATCH}" ]] || die "Missing patch: ${SS_SERVER_PATCH}"

SS_SERVER_VERSION="$(cd "${SOURCE_DIR}" && go list -m -f '{{.Version}}' github.com/Jigsaw-Code/outline-ss-server)"
[[ "${SS_SERVER_VERSION}" == "v1.7.3" ]] \
  || die "Expected outline-ss-server v1.7.3, found ${SS_SERVER_VERSION}."

apply_idempotent_patch "${SERVER_PATCH}"

log "Vendoring outline-ss-server ${SS_SERVER_VERSION} for the LAN-access patch..."
(cd "${SOURCE_DIR}" && go mod vendor)
apply_idempotent_patch "${SS_SERVER_PATCH}"

log "Outline source patches are ready."
