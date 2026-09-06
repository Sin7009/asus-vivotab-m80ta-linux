#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Запуск сборки в привилегированном контейнере Debian 13 (Trixie)..."

docker run --rm --privileged \
    --network host \
    -v /dev:/dev \
    -v "${PROJECT_DIR}:/workspace" \
    -w /workspace \
    debian:trixie \
    bash -c '
        set -euo pipefail
        echo "Установка сборочных утилит хоста..."
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
            util-linux

        udevadm control --reload || true
        bash /workspace/build/build.sh
    '
