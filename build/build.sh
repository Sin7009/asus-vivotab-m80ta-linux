#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Unified Image Builder v2.0
# Profiles:
#   BUILD_PROFILE=personal-debug (default): SSH on, key required, NOPASSWD sudo, Wi-Fi profile
#   BUILD_PROFILE=public: SSH off, no keys, standard sudo, clean
# ==============================================================================

BUILD_PROFILE="${BUILD_PROFILE:-personal-debug}"
if [ "$BUILD_PROFILE" != "personal-debug" ] && [ "$BUILD_PROFILE" != "public" ]; then
    echo "ОШИБКА: Неизвестный профиль сборки '$BUILD_PROFILE'. Допустимы: personal-debug, public." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

# Проверка обязательных условий для personal-debug
if [ "$BUILD_PROFILE" = "personal-debug" ]; then
    if [ ! -s "${PROJECT_DIR}/files/authorized_keys" ] && [ -z "${SSH_PUBKEY:-}" ]; then
        echo "=================================================================" >&2
        echo "КРИТИЧЕСКАЯ ОШИБКА: Профиль 'personal-debug' требует наличия SSH-ключа!" >&2
        echo "Поместите ваш публичный ключ в files/authorized_keys" >&2
        echo "или передайте его через переменную окружения SSH_PUBKEY." >&2
        echo "=================================================================" >&2
        exit 1
    fi
fi

COMMIT_SHORT=$(cd "${PROJECT_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "git")
IMAGE_NAME="m80ta-debian13-${COMMIT_SHORT}-${BUILD_PROFILE}.img"
IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-6144}" # 6.0 GB (гарантированно помещается на любую 8 ГБ флешку)

echo "================================================================="
echo "   Сборка образа Asus M80TA: ${IMAGE_NAME}                      "
echo "   Профиль: ${BUILD_PROFILE}                                     "
echo "================================================================="

echo "=== [1/9] Создание разреженного файла (${IMAGE_SIZE_MB} MB) ==="
rm -f "${IMAGE_PATH}" "${IMAGE_PATH}.xz" "${IMAGE_PATH}.xz.sha256"
truncate -s "${IMAGE_SIZE_MB}M" "${IMAGE_PATH}"

echo "=== [2/9] Разметка GPT (ESP 512MB + Btrfs Live Root) ==="
parted -s "${IMAGE_PATH}" mklabel gpt
parted -s "${IMAGE_PATH}" mkpart "M80TA_ESP" fat32 1MiB 513MiB
parted -s "${IMAGE_PATH}" set 1 esp on
parted -s "${IMAGE_PATH}" mkpart "M80TA_LIVE" btrfs 513MiB 100%

echo "=== [3/9] Привязка loop-устройства и форматирование ==="
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
trap cleanup EXIT INT TERM

ESP_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

udevadm settle || sleep 2

mkfs.vfat -F 32 -n "M80TA_ESP" "${ESP_PART}"
mkfs.btrfs -f -L "M80TA_LIVE" "${ROOT_PART}"

# Создаем субтома Btrfs (@ и @home)
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

echo "=== [4/9] Debootstrap Debian 13 (Trixie) amd64 ==="
debootstrap --arch=amd64 --variant=minbase trixie /mnt/rootfs http://deb.debian.org/debian

echo "=== [5/9] Настройка базовой системы и репозиториев ==="
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

# Копируем конфигурационные файлы
mkdir -p /mnt/rootfs/etc/systemd/system /mnt/rootfs/etc/sysctl.d /mnt/rootfs/etc/sddm.conf.d /mnt/rootfs/etc/xdg /mnt/rootfs/etc/ssh/sshd_config.d
cp "${PROJECT_DIR}/files/zram-generator.conf" /mnt/rootfs/etc/systemd/zram-generator.conf
cp "${PROJECT_DIR}/files/99-zram.conf" /mnt/rootfs/etc/sysctl.d/99-zram.conf
cp "${PROJECT_DIR}/files/sddm-autologin.conf" /mnt/rootfs/etc/sddm.conf.d/autologin.conf
cp "${PROJECT_DIR}/files/baloofilerc" /mnt/rootfs/etc/xdg/baloofilerc
cp "${PROJECT_DIR}/files/10-m80ta-ssh.conf" /mnt/rootfs/etc/ssh/sshd_config.d/10-m80ta.conf

# Сервис первого старта
cp "${PROJECT_DIR}/files/m80ta-firstboot.sh" /mnt/rootfs/usr/local/bin/m80ta-firstboot.sh
chmod +x /mnt/rootfs/usr/local/bin/m80ta-firstboot.sh
cp "${PROJECT_DIR}/files/m80ta-firstboot.service" /mnt/rootfs/etc/systemd/system/m80ta-firstboot.service

# Скрипт сбора диагностики
cp "${PROJECT_DIR}/files/m80ta-collect-debug.sh" /mnt/rootfs/usr/local/bin/m80ta-collect-debug
chmod +x /mnt/rootfs/usr/local/bin/m80ta-collect-debug

# Установщик на eMMC v2.0
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

echo "=== [6/9] Установка пакетов внутри chroot ==="
chroot /mnt/rootfs /bin/bash << CHROOT_EOF
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

# Настройка локалей
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Ядро и прошивки
apt-get install -y -qq --no-install-recommends \
    linux-image-amd64 \
    intel-microcode \
    firmware-brcm80211 \
    firmware-intel-sound \
    firmware-linux-nonfree \
    firmware-misc-nonfree

# Аппаратная часть: звук, тач, Wacom, питание
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

# Сеть, Wi-Fi бэкенд и SSH (ЯВНО ВКЛЮЧАЕМ wpasupplicant и сетевые утилиты)
apt-get install -y -qq --no-install-recommends \
    network-manager \
    network-manager-gnome \
    wpasupplicant \
    wireless-regdb \
    iw \
    rfkill \
    iproute2 \
    iputils-ping \
    ca-certificates \
    openssh-server \
    avahi-daemon

# Диагностические пакеты для аппаратного тестирования
apt-get install -y -qq --no-install-recommends \
    alsa-utils \
    pulseaudio-utils \
    libinput-tools \
    evtest \
    usbutils \
    pciutils \
    i2c-tools \
    dmidecode \
    mmc-utils \
    mokutil \
    gdisk \
    file

# Графический интерфейс
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
passwd -l root

# Настройка sudo в зависимости от профиля
if [ "${BUILD_PROFILE}" = "personal-debug" ]; then
    echo "vivotab ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/vivotab
    chmod 0440 /etc/sudoers.d/vivotab
    systemctl enable ssh
    systemctl enable avahi-daemon
else
    # В public-профиле sudo требует пароль, SSH выключен до явной активации
    rm -f /etc/sudoers.d/vivotab
    systemctl disable ssh || true
fi

# Ярлык установщика на рабочий стол
mkdir -p /home/vivotab/Desktop
cp /usr/share/applications/install-to-emmc.desktop /home/vivotab/Desktop/
chmod +x /home/vivotab/Desktop/install-to-emmc.desktop
chown -R 1000:1000 /home/vivotab/Desktop

# Проверка корректности синтаксиса sshd
sshd -t

# Удаление статических SSH host keys
rm -f /etc/ssh/ssh_host_*

# Очистка идентификаторов
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed /var/lib/m80ta-firstboot.done

# Включение системных служб
systemctl enable m80ta-firstboot.service
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable sddm
systemctl enable iio-sensor-proxy
systemctl enable power-profiles-daemon

# Настройка GRUB меню с двумя режимами (Safe C-State и Normal)
cat << 'GRUB_DEFAULT' > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Debian 13 M80TA"
GRUB_CMDLINE_LINUX_DEFAULT="intel_idle.max_cstate=1 fbcon=rotate:1 quiet splash loglevel=3"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_DEFAULT
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub

# Создание второго пункта меню без ограничения C-state для проверки автономности
cat << 'GRUB_CUSTOM' > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 \$0
menuentry 'Debian 13 (M80TA Normal - No C-state limit)' --class debian --class gnu-linux --class gnu --class os {
    load_video
    insmod gzio
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /@/boot/vmlinuz root=UUID=${ROOT_UUID} rootflags=subvol=@ fbcon=rotate:1 quiet splash loglevel=3 ro
    initrd /@/boot/initrd.img
}
GRUB_CUSTOM
chmod +x /etc/grub.d/40_custom

# Установка GRUB i386-efi в съемный путь EFI/BOOT/BOOTIA32.EFI
grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable
update-initramfs -u -k all
update-grub

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOT_EOF

echo "=== [7/9] Настройка ключей SSH и Wi-Fi профиля ==="
mkdir -p /mnt/rootfs/home/vivotab/.ssh

if [ "${BUILD_PROFILE}" = "personal-debug" ]; then
    if [ -f "${PROJECT_DIR}/files/authorized_keys" ]; then
        echo "Внедрение SSH-ключа из files/authorized_keys..."
        cp "${PROJECT_DIR}/files/authorized_keys" /mnt/rootfs/home/vivotab/.ssh/authorized_keys
    elif [ -n "${SSH_PUBKEY:-}" ]; then
        echo "Внедрение SSH-ключа из переменной SSH_PUBKEY..."
        echo "${SSH_PUBKEY}" > /mnt/rootfs/home/vivotab/.ssh/authorized_keys
    fi
    chmod 700 /mnt/rootfs/home/vivotab/.ssh
    chmod 600 /mnt/rootfs/home/vivotab/.ssh/authorized_keys
    chown -R 1000:1000 /mnt/rootfs/home/vivotab/.ssh

    if [ -f "${PROJECT_DIR}/files/m80ta-wifi.nmconnection" ]; then
        echo "Внедрение предварительно настроенного профиля Wi-Fi..."
        mkdir -p /mnt/rootfs/etc/NetworkManager/system-connections
        cp "${PROJECT_DIR}/files/m80ta-wifi.nmconnection" /mnt/rootfs/etc/NetworkManager/system-connections/
        chmod 600 /mnt/rootfs/etc/NetworkManager/system-connections/*
        chown root:root /mnt/rootfs/etc/NetworkManager/system-connections/*
    fi
else
    # В public-профиле ключ удален
    rm -rf /mnt/rootfs/home/vivotab/.ssh/authorized_keys
fi

echo "=== [8/9] Проверка и создание загрузчика IA32 ==="
mkdir -p /mnt/rootfs/boot/efi/EFI/BOOT

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

if [ ! -s /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI ]; then
    echo "Генерация автономного BOOTIA32.EFI..."
    chroot /mnt/rootfs grub-mkstandalone \
        -O i386-efi \
        -o /boot/efi/EFI/BOOT/BOOTIA32.EFI \
        -d /usr/lib/grub/i386-efi/ \
        --modules="part_gpt part_msdos fat btrfs normal search search_fs_uuid search_label linux" \
        "/boot/grub/grub.cfg=/boot/efi/EFI/BOOT/grub.cfg"
fi

echo "=== ПРОВЕРКА ОБРАЗА ДО РАЗМОНТИРОВАНИЯ ==="
# 1. Проверка BOOTIA32.EFI
test -s /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI || { echo "ОШИБКА: BOOTIA32.EFI пуст!" >&2; exit 1; }
file /mnt/rootfs/boot/efi/EFI/BOOT/BOOTIA32.EFI | grep -qiE 'PE32|EFI' || { echo "ОШИБКА: BOOTIA32.EFI не PE32!" >&2; exit 1; }

# 2. Проверка grub.cfg
test -s /mnt/rootfs/boot/efi/EFI/BOOT/grub.cfg || { echo "ОШИБКА: grub.cfg пуст!" >&2; exit 1; }
grep -q "$ROOT_UUID" /mnt/rootfs/boot/efi/EFI/BOOT/grub.cfg || { echo "ОШИБКА: UUID не совпадает!" >&2; exit 1; }

# 3. Проверка fstab
grep -q "$ROOT_UUID" /mnt/rootfs/etc/fstab || { echo "ОШИБКА: fstab root UUID не совпадает!" >&2; exit 1; }
grep -q "$ESP_UUID" /mnt/rootfs/etc/fstab || { echo "ОШИБКА: fstab esp UUID не совпадает!" >&2; exit 1; }

# 4. Проверка чистоты идентификаторов
test ! -s /mnt/rootfs/etc/machine-id || { echo "ОШИБКА: machine-id не пуст!" >&2; exit 1; }
ls /mnt/rootfs/etc/ssh/ssh_host_* >/dev/null 2>&1 && { echo "ОШИБКА: SSH host keys не удалены!" >&2; exit 1; } || true

# 5. Проверка наличия authorized_keys в соответствии с профилем
if [ "$BUILD_PROFILE" = "personal-debug" ]; then
    test -s /mnt/rootfs/home/vivotab/.ssh/authorized_keys || { echo "ОШИБКА: authorized_keys пуст в personal-debug!" >&2; exit 1; }
else
    test ! -f /mnt/rootfs/home/vivotab/.ssh/authorized_keys || { echo "ОШИБКА: authorized_keys присутствует в public!" >&2; exit 1; }
fi

sync

# Размонтируем ФС перед проверкой
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
set -e

echo "=== Проверка файловых систем разделов ==="
fsck.vfat -n "${ESP_PART}"
btrfs check --readonly "${ROOT_PART}"

cleanup
trap - EXIT INT TERM

echo "=== [9/9] Сжатие образа в ${IMAGE_NAME}.xz (xz -T0 -9) ==="
xz -T0 -9 -v "${IMAGE_PATH}"

echo "=== Проверка целостности сжатого архива (xz -t) ==="
xz -t "${IMAGE_PATH}.xz"

sha256sum "${IMAGE_PATH}.xz" > "${IMAGE_PATH}.xz.sha256"
chmod 644 "${IMAGE_PATH}.xz" "${IMAGE_PATH}.xz.sha256"

echo "================================================================="
echo "   СБОРКА УСПЕШНО ЗАВЕРШЕНА И ПРОТЕСТИРОВАНА!                    "
echo "   Готовый образ: ${IMAGE_PATH}.xz                              "
echo "   SHA256: $(cat "${IMAGE_PATH}.xz.sha256")                     "
echo "================================================================="
