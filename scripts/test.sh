#!/usr/bin/env bash
# Focused validation for this packaging project and its pinned Outline patches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${1:-${ROOT_DIR}/.build/outline-server}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -d "${SOURCE_DIR}" ]] || die "Outline source not found: ${SOURCE_DIR}"

for script in "${ROOT_DIR}/install.sh" "${ROOT_DIR}/raspberrypi/install.sh" "${ROOT_DIR}"/scripts/*.sh; do
  bash -n "${script}"
done
bash -n "${ROOT_DIR}/ec2/install.sh"
bash -n "${ROOT_DIR}/ec2/bootstrap.sh"

grep -Fq 'KEYS_PORT_FLAG=(--keys-port 80)' "${ROOT_DIR}/install.sh"
grep -Fq 'PREFIX_FLAG=(--prefix "POST%20")' "${ROOT_DIR}/install.sh"
grep -Fq 'LAN_ACCESS=1' "${ROOT_DIR}/install.sh"
grep -Fq 'declare -i FLAGS_KEYS_PORT=80' "${ROOT_DIR}/scripts/install_server.sh"
grep -Fq 'declare FLAGS_PREFIX="POST%20"' "${ROOT_DIR}/scripts/install_server.sh"
grep -Fq 'SB_ALLOW_PRIVATE_TARGETS=true' "${ROOT_DIR}/install.sh"
grep -Fq 'TASK_ARCH="arm64"' "${ROOT_DIR}/scripts/build_image.sh"
grep -Fq 'TARGET_ARCH="${TASK_ARCH}"' "${ROOT_DIR}/scripts/build_image.sh"
grep -Fq 'package_install curl-minimal' "${ROOT_DIR}/scripts/setup_build_deps.sh"
grep -Fq 'package_install gnupg2-minimal' "${ROOT_DIR}/scripts/setup_build_deps.sh"
bash "${ROOT_DIR}/scripts/install_server.sh" --help | grep -Fq 'default: 80'
bash "${ROOT_DIR}/ec2/install.sh" --help | grep -Fq -- '--api-port 443'
bash "${ROOT_DIR}/ec2/bootstrap.sh" --help | grep -Fq 'Outline Server EC2 bootstrap (v1.12.3-r3)'

bash "${ROOT_DIR}/scripts/apply_outline_patches.sh" "${SOURCE_DIR}"

(cd "${SOURCE_DIR}" && go test ./outline_patch_tests)
(cd "${SOURCE_DIR}" && go test github.com/Jigsaw-Code/outline-ss-server/cmd/outline-ss-server)

mkdir -p "${SOURCE_DIR}/build"
TEST_OUTPUT="$(mktemp -d "${SOURCE_DIR}/build/outline-patch-test.XXXXXX")"
trap 'rm -rf "${TEST_OUTPUT}"' EXIT

(cd "${SOURCE_DIR}" && npx tsc -p src/shadowbox --outDir "${TEST_OUTPUT}")
(cd "${SOURCE_DIR}" && npx jasmine "${TEST_OUTPUT}/server/manager_service.spec.js")

printf 'All focused project checks passed.\n'
