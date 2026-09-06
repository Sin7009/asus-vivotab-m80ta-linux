#!/bin/bash
set -e

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - 1-Click eMMC Installer
# Clones running Live system to internal /dev/mmcblk0 with IA32 GRUB & Btrfs (zstd)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Перезапуск с правами sudo..."
    exec sudo bash "$0" "$@"
fi

TARGET_DEV="/dev/mmcblk0"

clear
echo "================================================================="
echo "   Установка Debian 13 (Trixie) на внутреннюю eMMC Asus M80TA   "
echo "================================================================="
echo ""

if [ ! -b "$TARGET_DEV" ]; then
    echo "ОШИБКА: Устройство eMMC $TARGET_DEV не найдено!"
    echo "Доступные блочные устройства в системе:"
    lsblk
    exit 1
fi

EMMC_SIZE=$(lsblk -bno SIZE "$TARGET_DEV" | head -n1 | awk '{printf "%.1f GB", $1/1024/1024/1024}')
EMMC_MODEL=$(lsblk -no MODEL "$TARGET_DEV" | head -n1)

echo "Обнаружен внутренний накопитель: $TARGET_DEV ($EMMC_SIZE) $EMMC_MODEL"
echo ""
echo "ВНИМАНИЕ!"
echo "Все текущие разделы и данные (включая Windows) на $TARGET_DEV будут"
echo "БЕЗВОЗВРАТНО УДАЛЕНЫ!"
echo ""
read -rp "Вы действительно хотите начать установку? Введите 'YES': " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Отмена установки. Никаких изменений не внесено."
    exit 0
fi

echo ""
echo "[1/6] Разметка eMMC диска ($TARGET_DEV)..."
# Снимаем блокировки и размонтируем, если что-то смонтировано
swapoff -a 2>/dev/null || true
umount -R /mnt/target 2>/dev/null || true
for part in ${TARGET_DEV}p*; do
    umount "$part" 2>/dev/null || true
done

# Очистка начала и конца диска от старых сигнатур GPT/MBR
dd if=/dev/zero of="$TARGET_DEV" bs=1M count=10 status=none 2>/dev/null || true

# Создание GPT: ESP (512MB) + Btrfs Root (всё оставшееся место)
parted -s "$TARGET_DEV" mklabel gpt
parted -s "$TARGET_DEV" mkpart "ESP" fat32 1MiB 513MiB
parted -s "$TARGET_DEV" set 1 esp on
parted -s "$TARGET_DEV" mkpart "M80TA_ROOT" btrfs 513MiB 100%

# Ждем появления разделов
udevadm settle || sleep 2

ESP_PART="${TARGET_DEV}p1"
ROOT_PART="${TARGET_DEV}p2"

echo "[2/6] Форматирование разделов (FAT32 + Btrfs со сжатием zstd)..."
mkfs.vfat -F 32 -n "M80TA_ESP" "$ESP_PART"
mkfs.btrfs -f -L "M80TA_ROOT" "$ROOT_PART"

echo "[3/6] Создание Btrfs субтомов (@ и @home)..."
mkdir -p /mnt/target_btrfs
mount "$ROOT_PART" /mnt/target_btrfs
btrfs subvolume create /mnt/target_btrfs/@
btrfs subvolume create /mnt/target_btrfs/@home
umount /mnt/target_btrfs
rmdir /mnt/target_btrfs

mkdir -p /mnt/target
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@ "$ROOT_PART" /mnt/target
mkdir -p /mnt/target/home /mnt/target/boot/efi
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@home "$ROOT_PART" /mnt/target/home
mount "$ESP_PART" /mnt/target/boot/efi

echo "[4/6] Клонирование системы на eMMC (это займет 2-3 минуты)..."
rsync -aAXv --info=progress2 \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / /mnt/target/

echo "[5/6] Настройка fstab и генерация UUID..."
ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat <<EOF > /mnt/target/etc/fstab
# /etc/fstab: static file system information for Asus VivoTab Note 8 (M80TA)
UUID=$ROOT_UUID  /          btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@      0  0
UUID=$ROOT_UUID  /home      btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@home  0  0
UUID=$ESP_UUID   /boot/efi  vfat   umask=0077                                            0  1
EOF

echo "[6/6] Установка 32-битного UEFI GRUB (--no-nvram --removable)..."
mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
mount --bind /run /mnt/target/run

chroot /mnt/target grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable
chroot /mnt/target update-grub

# Убеждаемся, что BOOTIA32.EFI на месте
if [ ! -f /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI ]; then
    echo "Копирование резервного загрузчика в EFI/BOOT/BOOTIA32.EFI..."
    mkdir -p /mnt/target/boot/efi/EFI/BOOT
    cp /mnt/target/boot/efi/EFI/debian/grubia32.efi /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI 2>/dev/null || true
fi

# Демонтируем chroot бинды
umount -l /mnt/target/dev/pts 2>/dev/null || true
umount -l /mnt/target/dev 2>/dev/null || true
umount -l /mnt/target/proc 2>/dev/null || true
umount -l /mnt/target/sys 2>/dev/null || true
umount -l /mnt/target/run 2>/dev/null || true

umount /mnt/target/boot/efi
umount /mnt/target/home
umount /mnt/target

echo ""
echo "================================================================="
echo "   УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                                 "
echo "================================================================="
echo "Теперь вы можете извлечь USB-флешку и перезагрузить планшет."
echo "Он загрузится во внутреннюю систему Debian 13 Plasma Mobile."
echo ""
read -rp "Перезагрузить планшет прямо сейчас? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    reboot
fi
