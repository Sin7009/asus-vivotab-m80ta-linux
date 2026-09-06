#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Debian 13 (Trixie) Image Builder v1.1
# Produces bootable hybrid Live/Installer disk image with IA32 UEFI GRUB
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

IMAGE_NAME="m80ta-debian13-plasma-mobile-v1.1.img"
IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"
IMAGE_SIZE_MB=7680 # 7.5 GB

echo "=== [1/8] Создание разреженного образа диска (${IMAGE_SIZE_MB} MB) ==="
rm -f "${IMAGE_PATH}" "${IMAGE_PATH}.xz" "${IMAGE_PATH}.xz.sha256"
truncate -s "${IMAGE_SIZE_MB}M" "${IMAGE_PATH}"

echo "=== [2/8] Разметка GPT (ESP 512MB + Btrfs Live Root) ==="
parted -s "${IMAGE_PATH}" mklabel gpt
parted -s "${IMAGE_PATH}" mkpart "M80TA_ESP" fat32 1MiB 513MiB
parted -s "${IMAGE_PATH}" set 1 esp on
parted -s "${IMAGE_PATH}" mkpart "M80TA_LIVE" btrfs 513MiB 100%

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
# Помечаем Live-образ как M80TA_LIVE, исключая конфликт меток с M80TA_SYS на eMMC
mkfs.btrfs -f -L "M80TA_LIVE" "${ROOT_PART}"

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
mkdir -p /mnt/rootfs/etc/systemd/system /mnt/rootfs/etc/sysctl.d /mnt/rootfs/etc/sddm.conf.d /mnt/rootfs/etc/xdg /mnt/rootfs/etc/ssh/sshd_config.d
cp "${PROJECT_DIR}/files/zram-generator.conf" /mnt/rootfs/etc/systemd/zram-generator.conf
cp "${PROJECT_DIR}/files/99-zram.conf" /mnt/rootfs/etc/sysctl.d/99-zram.conf
cp "${PROJECT_DIR}/files/sddm-autologin.conf" /mnt/rootfs/etc/sddm.conf.d/autologin.conf
cp "${PROJECT_DIR}/files/baloofilerc" /mnt/rootfs/etc/xdg/baloofilerc

# Конфигурация защищенного SSH
cp "${PROJECT_DIR}/files/10-m80ta-ssh.conf" /mnt/rootfs/etc/ssh/sshd_config.d/10-m80ta.conf

# Скрипт и сервис первого безопасного старта
cp "${PROJECT_DIR}/files/m80ta-firstboot.sh" /mnt/rootfs/usr/local/bin/m80ta-firstboot.sh
chmod +x /mnt/rootfs/usr/local/bin/m80ta-firstboot.sh
cp "${PROJECT_DIR}/files/m80ta-firstboot.service" /mnt/rootfs/etc/systemd/system/m80ta-firstboot.service

# Безопасный скрипт 1-Click установки на eMMC
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

# Ядро и прошивки (включая критический firmware-intel-sound для DSP SST)
apt-get install -y -qq --no-install-recommends \
    linux-image-amd64 \
    intel-microcode \
    firmware-brcm80211 \
    firmware-intel-sound \
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

# Сеть, Wi-Fi бэкенд и SSH (ЯВНО ВКЛЮЧАЕМ wpasupplicant, wireless-regdb, iw, rfkill)
apt-get install -y -qq --no-install-recommends \
    network-manager \
    network-manager-gnome \
    wpasupplicant \
    wireless-regdb \
    iw \
    rfkill \
    openssh-server \
    avahi-daemon

# Инструменты тестирования и диагностики оборудования (для TESTING.md)
apt-get install -y -qq --no-install-recommends \
    alsa-utils \
    pulseaudio-utils \
    libinput-tools \
    evtest \
    usbutils \
    pciutils \
    i2c-tools

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
# Блокировка пароля root (вход только через sudo)
passwd -l root

# Разрешаем NOPASSWD для пользователя vivotab для комфортной отладки планшета
echo "vivotab ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/vivotab
chmod 0440 /etc/sudoers.d/vivotab

# Ярлык установщика на рабочий стол vivotab
mkdir -p /home/vivotab/Desktop
cp /usr/share/applications/install-to-emmc.desktop /home/vivotab/Desktop/
chmod +x /home/vivotab/Desktop/install-to-emmc.desktop
chown -R vivotab:vivotab /home/vivotab/Desktop

# Удаляем статические SSH host keys (будут сгенерированы уникально при первом старте m80ta-firstboot)
rm -f /etc/ssh/ssh_host_*

# Обнуляем machine-id и маркер первого запуска
truncate -s 0 /etc/machine-id
rm -f /var/lib/m80ta-firstboot.done

# Включение SSH и mDNS служб по умолчанию
systemctl enable ssh
systemctl enable avahi-daemon
systemctl enable m80ta-firstboot.service
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable sddm
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

echo "=== [6.1/8] Настройка авторизации SSH и преднастроенного Wi-Fi ==="
mkdir -p /mnt/rootfs/home/vivotab/.ssh
if [ -f "${PROJECT_DIR}/files/authorized_keys" ]; then
    echo "Внедрение SSH-ключа из files/authorized_keys..."
    cp "${PROJECT_DIR}/files/authorized_keys" /mnt/rootfs/home/vivotab/.ssh/authorized_keys
elif [ -n "${SSH_PUBKEY:-}" ]; then
    echo "Внедрение SSH-ключа из переменной SSH_PUBKEY..."
    echo "${SSH_PUBKEY}" > /mnt/rootfs/home/vivotab/.ssh/authorized_keys
else
    echo "ВНИМАНИЕ: files/authorized_keys не найден и SSH_PUBKEY пуст. Вход по SSH будет закрыт до добавления ключа!"
fi

chmod 700 /mnt/rootfs/home/vivotab/.ssh
if [ -f /mnt/rootfs/home/vivotab/.ssh/authorized_keys ]; then
    chmod 600 /mnt/rootfs/home/vivotab/.ssh/authorized_keys
fi
chown -R 1000:1000 /mnt/rootfs/home/vivotab

# Если предоставлен профиль Wi-Fi, внедряем его в NetworkManager
if [ -f "${PROJECT_DIR}/files/m80ta-wifi.nmconnection" ]; then
    echo "Внедрение предварительно настроенного профиля Wi-Fi..."
    mkdir -p /mnt/rootfs/etc/NetworkManager/system-connections
    cp "${PROJECT_DIR}/files/m80ta-wifi.nmconnection" /mnt/rootfs/etc/NetworkManager/system-connections/
    chmod 600 /mnt/rootfs/etc/NetworkManager/system-connections/*
    chown root:root /mnt/rootfs/etc/NetworkManager/system-connections/*
fi

echo "=== [7/8] Проверка и создание отказоустойчивого загрузчика IA32 ==="
mkdir -p /mnt/rootfs/boot/efi/EFI/BOOT

# Первичный grub.cfg с явным поиском по UUID root-раздела текущего носителя
cat << EOF > /mnt/rootfs/boot/efi/EFI/BOOT/grub.cfg
# Search strictly by current root partition UUID
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
if [ -e (\$root)/@/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/@/boot/grub
    configfile (\$root)/@/boot/grub/grub.cfg
elif [ -e (\$root)/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/boot/grub
    configfile (\$root)/boot/grub/grub.cfg
fi
EOF

# Автономный BOOTIA32.EFI
if [ ! -f /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI ] || [ ! -s /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI ]; then
    echo "Генерация автономного BOOTIA32.EFI через grub-mkstandalone..."
    chroot /mnt/rootfs grub-mkstandalone \
        -O i386-efi \
        -o /boot/efi/EFI/BOOT/BOOTIA32.EFI \
        -d /usr/lib/grub/i386-efi/ \
        --modules="part_gpt part_msdos fat btrfs normal search search_fs_uuid search_label linux" \
        "/boot/grub/grub.cfg=/boot/efi/EFI/BOOT/grub.cfg"
fi

# Строгая валидация файлов загрузчика
test -s /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI || {
    echo "ОШИБКА: BOOTIA32.EFI не сформирован или пуст!" >&2
    exit 1
}

test -s /mnt/rootfs/boot/efi/EFI/BOOT/grub.cfg || {
    echo "ОШИБКА: grub.cfg в ESP не сформирован или пуст!" >&2
    exit 1
}

echo "Содержимое каталога EFI/BOOT:"
ls -lh /mnt/rootfs/boot/efi/EFI/BOOT/

# Демонтируем все
cleanup
trap - EXIT

echo "=== [8/8] Сжатие образа в ${IMAGE_NAME}.xz (xz -T0 -9) ==="
xz -T0 -9 -v "${IMAGE_PATH}"

sha256sum "${IMAGE_PATH}.xz" > "${IMAGE_PATH}.xz.sha256"
chmod 644 "${IMAGE_PATH}.xz" "${IMAGE_PATH}.xz.sha256"

echo "================================================================="
echo "   СБОРКА УСПЕШНО ЗАВЕРШЕНА!                                     "
echo "   Готовый образ: ${IMAGE_PATH}.xz                              "
echo "   SHA256: $(cat "${IMAGE_PATH}.xz.sha256")                     "
echo "================================================================="
