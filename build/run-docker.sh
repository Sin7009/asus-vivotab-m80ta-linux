#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "${PROJECT_DIR}/output"

BUILD_PROFILE="${BUILD_PROFILE:-personal-debug}"
CONTAINER_NAME="m80ta-build-$$"

cleanup() {
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Запуск сборки в контейнере Debian 13 (Trixie) [${CONTAINER_NAME}]..."
echo "Профиль сборки: ${BUILD_PROFILE}"

docker run --rm --privileged \
    --name "${CONTAINER_NAME}" \
    -v /dev:/dev \
    -v "${PROJECT_DIR}:/workspace" \
    -w /workspace \
    -e SSH_PUBKEY="${SSH_PUBKEY:-}" \
    -e BUILD_PROFILE="${BUILD_PROFILE}" \
    -e IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-6144}" \
    debian:trixie \
    bash -c '
        set -euo pipefail
        echo "=== Установка инструментов сборщика на хост ==="
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            debootstrap \
            parted \
            dosfstools \
            btrfs-progs \
            udev \
            kmod \
            xz-utils \
            ca-certificates \
            curl \
            util-linux \
            grub-efi-ia32-bin \
            mtools \
            file

        bash /workspace/build/build.sh
    '
