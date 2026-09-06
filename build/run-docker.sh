#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "${PROJECT_DIR}/output"
chmod 777 "${PROJECT_DIR}/output"

echo "Запуск сборки в привилегированном контейнере Debian 13 (Trixie)..."

docker run --rm --privileged \
    --network host \
    -v /dev:/dev \
    -v "${PROJECT_DIR}:/workspace" \
    -w /workspace \
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
        chmod -R 777 /workspace/output || true
    '
