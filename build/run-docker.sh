#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "${PROJECT_DIR}/output"

CONTAINER_NAME="m80ta-build-$$"

cleanup() {
    echo "Завершение и очистка контейнера ${CONTAINER_NAME}..."
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Запуск сборки в привилегированном контейнере Debian 13 (Trixie) [${CONTAINER_NAME}]..."

docker run --rm --privileged \
    --name "${CONTAINER_NAME}" \
    --network host \
    -v /dev:/dev \
    -v "${PROJECT_DIR}:/workspace" \
    -w /workspace \
    -e SSH_PUBKEY="${SSH_PUBKEY:-}" \
    debian:trixie \
    bash -c '
        set -euo pipefail
        echo "=== [0/8] Установка сборочных утилит хоста ==="
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
            mtools

        bash /workspace/build/build.sh
    '
