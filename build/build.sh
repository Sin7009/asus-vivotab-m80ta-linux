#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Debian 13 (Trixie) Image Builder
# Produces bootable hybrid Live/Installer disk image with IA32 UEFI GRUB
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

IMAGE_NAME="m80ta-debian13-plasma-mobile.img"
IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"
IMAGE_SIZE_MB=7680 # 7.5 GB

echo "=== [1/8] Создание разреженного образа диска (${IMAGE_SIZE_MB} MB) ==="
rm -f "${IMAGE_PATH}" "${IMAGE_PATH}.xz" "${IMAGE_PATH}.xz.sha256"
truncate -s "${IMAGE_SIZE_MB}M" "${IMAGE_PATH}"

echo "=== [2/8] Разметка GPT (ESP 512MB + Btrfs Root) ==="
parted -s "${IMAGE_PATH}" mklabel gpt
parted -s "${IMAGE_PATH}" mkpart "ESP" fat32 1MiB 513MiB
parted -s "${IMAGE_PATH}" set 1 esp on
parted -s "${IMAGE_PATH}" mkpart "M80TA_ROOT" btrfs 513MiB 100%

echo "=== [3/8] Настройка loop-устройства и форматирование ==="
LOOP_DEV=$(losetup -fP --show "${IMAGE_PATH}")
echo "Привязано loop-устройство: ${LOOP_DEV}"

cleanup() {
    echo "Очистка и размонтирование..."
    set +e
    umount -l /mnt/rootfs/dev/pts 2>/dev/null || true
    umount -l /mnt/rootfs/dev 2>/dev/null || true
    umount -l /mnt/rootfs/proc 2>/dev/null || true
    umount -l /mnt/rootfs/sys 2>/dev/null || true
    umount -l /mnt/rootfs/run 2>/dev/null || true
    umount -l /mnt/rootfs/boot/efi 2>/dev/null || true
    umount -l /mnt/rootfs/home 2>/dev/null || true
    umount -l /mnt/rootfs 2>/dev/null || true
    umount -l /mnt/tmp_btrfs 2>/dev/null || true
    if [ -n "${LOOP_DEV:-}" ] && losetup "${LOOP_DEV}" 2>/dev/null; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

ESP_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# Ждем девайсы
udevadm settle || sleep 2

mkfs.vfat -F 32 -n "M80TA_ESP" "${ESP_PART}"
mkfs.btrfs -f -L "M80TA_ROOT" "${ROOT_PART}"

# Создаем субтома Btrfs
mkdir -p /mnt/tmp_btrfs
mount "${ROOT_PART}" /mnt/tmp_btrfs
btrfs subvolume create /mnt/tmp_btrfs/@
btrfs subvolume create /mnt/tmp_btrfs/@home
umount /mnt/tmp_btrfs
rmdir /mnt/tmp_btrfs

mkdir -p /mnt/rootfs
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@ "${ROOT_PART}" /mnt/rootfs
mkdir -p /mnt/rootfs/home /mnt/rootfs/boot/efi
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@home "${ROOT_PART}" /mnt/rootfs/home
mount "${ESP_PART}" /mnt/rootfs/boot/efi

echo "=== [4/8] Debootstrap Debian 13 (Trixie) amd64 ==="
debootstrap --arch=amd64 --variant=minbase trixie /mnt/rootfs http://deb.debian.org/debian

echo "=== [5/8] Настройка базовой системы и репозиториев ==="
cat << 'EOF' > /mnt/rootfs/etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF

ESP_UUID=$(blkid -s UUID -o value "${ESP_PART}")
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")

cat << EOF > /mnt/rootfs/etc/fstab
UUID=${ROOT_UUID}  /          btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@      0  0
UUID=${ROOT_UUID}  /home      btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@home  0  0
UUID=${ESP_UUID}   /boot/efi  vfat   umask=0077                                            0  1
EOF

echo "vivotab-m80ta" > /mnt/rootfs/etc/hostname
cat << 'EOF' > /mnt/rootfs/etc/hosts
127.0.0.1   localhost
127.0.1.1   vivotab-m80ta
::1         localhost ip6-localhost ip6-loopback
EOF

# Копируем конфигурационные файлы из проекта
mkdir -p /mnt/rootfs/etc/systemd /mnt/rootfs/etc/sysctl.d /mnt/rootfs/etc/sddm.conf.d /mnt/rootfs/etc/xdg
cp "${PROJECT_DIR}/files/zram-generator.conf" /mnt/rootfs/etc/systemd/zram-generator.conf
cp "${PROJECT_DIR}/files/99-zram.conf" /mnt/rootfs/etc/sysctl.d/99-zram.conf
cp "${PROJECT_DIR}/files/sddm-autologin.conf" /mnt/rootfs/etc/sddm.conf.d/autologin.conf
cp "${PROJECT_DIR}/files/baloofilerc" /mnt/rootfs/etc/xdg/baloofilerc

# Скрипт 1-Click установки на eMMC
cp "${PROJECT_DIR}/files/install-to-emmc.sh" /mnt/rootfs/usr/local/bin/install-to-emmc
chmod +x /mnt/rootfs/usr/local/bin/install-to-emmc
mkdir -p /mnt/rootfs/usr/share/applications
cp "${PROJECT_DIR}/files/install-to-emmc.desktop" /mnt/rootfs/usr/share/applications/

# Монтируем виртуальные ФС для chroot
mount --bind /dev /mnt/rootfs/dev
mount --bind /dev/pts /mnt/rootfs/dev/pts
mount --bind /proc /mnt/rootfs/proc
mount --bind /sys /mnt/rootfs/sys
mount --bind /run /mnt/rootfs/run

echo "=== [6/8] Установка пакетов внутри chroot ==="
chroot /mnt/rootfs /bin/bash << 'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get update -qq

# Базовые утилиты и локализация
apt-get install -y -qq --no-install-recommends \
    systemd-sysv \
    systemd-timesyncd \
    systemd-resolved \
    locales \
    sudo \
    curl \
    wget \
    nano \
    htop \
    fastfetch \
    btrfs-progs \
    dosfstools \
    rsync \
    parted \
    systemd-zram-generator

# Настройка локалей (en_US и ru_RU)
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Ядро и прошивки
apt-get install -y -qq --no-install-recommends \
    linux-image-amd64 \
    intel-microcode \
    firmware-brcm80211 \
    firmware-linux-nonfree \
    firmware-misc-nonfree

# Оборудование M80TA: звук (Intel SST), акселерометр, тач, Wacom, питание
apt-get install -y -qq --no-install-recommends \
    alsa-ucm-conf \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    iio-sensor-proxy \
    libinput-bin \
    libwacom-common \
    libwacom-bin \
    xserver-xorg-input-wacom \
    bluez \
    bluez-tools \
    upower \
    power-profiles-daemon

# Сеть и SSH
apt-get install -y -qq --no-install-recommends \
    network-manager \
    network-manager-gnome \
    openssh-server \
    avahi-daemon

# Графическое окружение Plasma Mobile + XFCE4 fallback
apt-get install -y -qq --no-install-recommends \
    plasma-mobile \
    plasma-mobile-core \
    maliit-keyboard \
    polkit-kde-agent-1 \
    xwayland \
    sddm \
    xfce4 \
    xfce4-terminal \
    foot \
    xournalpp \
    falkon

# Загрузчик GRUB 32-bit UEFI
apt-get install -y -qq --no-install-recommends \
    grub-efi-ia32 \
    grub-efi-ia32-bin \
    grub-common \
    efibootmgr \
    mtools

# Создание пользователя vivotab
useradd -m -s /bin/bash -G sudo,audio,video,input,plugdev,netdev vivotab
echo "vivotab:vivotab" | chpasswd
echo "root:vivotab" | chpasswd

# Права sudo без пароля
echo "vivotab ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/vivotab
chmod 0440 /etc/sudoers.d/vivotab

# Внедрение SSH ключа
mkdir -p /home/vivotab/.ssh /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAING3W3cV+j3wYoGAp85wSGbhLEX3LYoCoERsBsXn+cjP keenetic" > /home/vivotab/.ssh/authorized_keys
cp /home/vivotab/.ssh/authorized_keys /root/.ssh/authorized_keys
chmod 700 /home/vivotab/.ssh /root/.ssh
chmod 600 /home/vivotab/.ssh/authorized_keys /root/.ssh/authorized_keys
chown -R vivotab:vivotab /home/vivotab/.ssh

# Ярлык установщика на рабочий стол vivotab
mkdir -p /home/vivotab/Desktop
cp /usr/share/applications/install-to-emmc.desktop /home/vivotab/Desktop/
chmod +x /home/vivotab/Desktop/install-to-emmc.desktop
chown -R vivotab:vivotab /home/vivotab/Desktop

# Генерация ключей хоста SSH и включение сервисов
ssh-keygen -A
systemctl enable ssh
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable sddm
systemctl enable avahi-daemon
systemctl enable iio-sensor-proxy
systemctl enable power-profiles-daemon

# Настройка GRUB для Bay Trail C-state бага и ориентации консоли
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="intel_idle.max_cstate=1 fbcon=rotate:1 quiet splash loglevel=3"/' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub

# Установка GRUB i386-efi в съемный путь EFI/BOOT/BOOTIA32.EFI
grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable
update-grub

# Очистка кеша пакетов для уменьшения размера образа
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOT_EOF

echo "=== [7/8] Проверка и создание отказоустойчивого загрузчика IA32 ==="
mkdir -p /mnt/rootfs/boot/efi/EFI/BOOT

# Создаем standalone загрузчик с встроенными модулями и прямым поиском Btrfs корня
cat << 'EOF' > /tmp/embedded_grub.cfg
search --no-floppy --set=root --label M80TA_ROOT
if [ -e ($root)/@/boot/grub/grub.cfg ]; then
    set prefix=($root)/@/boot/grub
    configfile ($root)/@/boot/grub/grub.cfg
elif [ -e ($root)/boot/grub/grub.cfg ]; then
    set prefix=($root)/boot/grub
    configfile ($root)/boot/grub/grub.cfg
fi
EOF

cp /tmp/embedded_grub.cfg /mnt/rootfs/boot/efi/EFI/BOOT/grub.cfg

# Если grub-install не создал BOOTIA32.EFI или создал пустой, генерируем полноценный standalone EFI
if [ ! -f /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI ] || [ ! -s /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI ]; then
    echo "Генерация автономного BOOTIA32.EFI через grub-mkstandalone..."
    chroot /mnt/rootfs grub-mkstandalone \
        -O i386-efi \
        -o /boot/efi/EFI/BOOT/BOOTIA32.EFI \
        -d /usr/lib/grub/i386-efi/ \
        --modules="part_gpt part_msdos fat btrfs normal search search_fs_uuid search_label linux" \
        "/boot/grub/grub.cfg=/boot/efi/EFI/BOOT/grub.cfg"
fi

echo "Содержимое каталога EFI/BOOT:"
ls -lh /mnt/rootfs/boot/efi/EFI/BOOT/

# Демонтируем все
cleanup
trap - EXIT

echo "=== [8/8] Сжатие образа в ${IMAGE_NAME}.xz (xz -T0 -9) ==="
xz -T0 -9 -v "${IMAGE_PATH}"

sha256sum "${IMAGE_PATH}.xz" > "${IMAGE_PATH}.xz.sha256"

echo "================================================================="
echo "   СБОРКА УСПЕШНО ЗАВЕРШЕНА!                                     "
echo "   Готовый образ: ${IMAGE_PATH}.xz                              "
echo "   SHA256: $(cat "${IMAGE_PATH}.xz.sha256")                     "
echo "================================================================="
