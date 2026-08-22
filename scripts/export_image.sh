#!/usr/bin/env bash
#
# Save the built Outline image to a tarball for transfer to a Raspberry Pi.
#
# On build machine:
#   ./scripts/export_image.sh
#   scp outline-shadowbox-arm64.tar.gz pi@raspberrypi:~/
#
# On the Pi:
#   docker load < outline-shadowbox-arm64.tar.gz
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-localhost/outline/shadowbox:stable}"
OUT_FILE="${1:-${ROOT_DIR}/outline-shadowbox-$(uname -m).tar.gz}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "Docker required."
docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1 || die "Image not found: ${IMAGE_TAG}. Run ./scripts/build_image.sh first."

echo "==> Exporting ${IMAGE_TAG} -> ${OUT_FILE}"
docker save "${IMAGE_TAG}" | gzip > "${OUT_FILE}"
ls -lh "${OUT_FILE}"
echo "Transfer with: scp $(basename "${OUT_FILE}") pi@<pi-host>:~/"
echo "On Pi load with: gunzip -c $(basename "${OUT_FILE}") | docker load"
