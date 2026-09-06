#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Safe eMMC Installer
# Verifies device hardware type (MMC vs SD), prevents self-overwrite,
# and configures unique UUID-based IA32 GRUB bootloader.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Перезапуск с правами root..."
    exec sudo bash "$0" "$@"
fi

clear
echo "================================================================="
echo "   Безопасная установка Debian 13 на внутреннюю eMMC Asus M80TA "
echo "================================================================="
echo ""

# 1. Поиск подключенных MMC/SD устройств
echo "[*] Сканирование блочных устройств хранения..."
echo ""
lsblk -o NAME,TYPE,SIZE,RM,ROTA,TRAN,MOUNTPOINTS
echo ""

# 2. Определение текущего загрузочного носителя
BOOTED_DEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
if [ -z "$BOOTED_DEV" ]; then
    BOOTED_DEV=$(findmnt -n -o SOURCE / | sed -E 's/[0-9]+$//; s/p[0-9]+$//')
fi
echo "[*] Текущий системный носитель (Live): ${BOOTED_DEV:-не определен}"

# 3. Поиск кандидатов на роль внутренней eMMC
CANDIDATES=()
for dev_path in /sys/block/mmcblk*; do
    [ -e "$dev_path" ] || continue
    dev_name=$(basename "$dev_path")
    dev_node="/dev/${dev_name}"

    # Проверка типа устройства (MMC vs SD)
    dev_type="UNKNOWN"
    if [ -f "${dev_path}/device/type" ]; then
        dev_type=$(cat "${dev_path}/device/type")
    fi

    # Проверка съемности
    is_removable="1"
    if [ -f "${dev_path}/removable" ]; then
        is_removable=$(cat "${dev_path}/removable")
    fi

    dev_size=$(lsblk -bno SIZE "$dev_node" 2>/dev/null | head -n1 | awk '{printf "%.1f GB", $1/1024/1024/1024}')
    hw_name="N/A"
    if [ -f "${dev_path}/device/name" ]; then
        hw_name=$(cat "${dev_path}/device/name")
    fi

    # Отсекаем устройство, с которого загружена текущая система
    if [[ "${BOOTED_DEV}" == *"${dev_name}"* ]]; then
        echo "[-] Пропуск $dev_node ($dev_size): это текущий загрузочный носитель!"
        continue
    fi

    # Настоящая внутренняя eMMC имеет тип MMC и non-removable (0)
    if [ "$dev_type" = "MMC" ]; then
        echo "[+] Обнаружена внутренняя eMMC: $dev_node ($dev_size, чип: $hw_name, removable=$is_removable)"
        CANDIDATES+=("$dev_node")
    else
        echo "[?] Найдено устройство $dev_node ($dev_size, тип: $dev_type) — вероятно, внешняя MicroSD карта!"
    fi
done

echo ""
if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "ОШИБКА: Внутренняя eMMC (тип MMC) не обнаружена среди доступных неиспользуемых дисков!"
    echo "Убедитесь, что система загружена с USB-флешки, а не установлена на eMMC."
    exit 1
fi

TARGET_DEV="${CANDIDATES[0]}"
if [ ${#CANDIDATES[@]} -gt 1 ]; then
    echo "Найдено несколько подходящих MMC накопителей:"
    for i in "${!CANDIDATES[@]}"; do
        echo "  $((i+1))) ${CANDIDATES[$i]}"
    done
    read -rp "Выберите номер целевого диска: " SELECTED_IDX
    TARGET_DEV="${CANDIDATES[$((SELECTED_IDX-1))]}"
fi

echo "-----------------------------------------------------------------"
echo "ЦЕЛЕВОЙ ДИСК ДЛЯ УСТАНОВКИ: $TARGET_DEV"
echo "Модель/Чип: $(cat /sys/block/$(basename "$TARGET_DEV")/device/name 2>/dev/null || echo 'N/A')"
echo "Тип памяти: $(cat /sys/block/$(basename "$TARGET_DEV")/device/type 2>/dev/null || echo 'N/A')"
echo "Размер:     $(lsblk -bno SIZE "$TARGET_DEV" | head -n1 | awk '{printf "%.1f GB", $1/1024/1024/1024}')"
echo "-----------------------------------------------------------------"
echo ""
echo "ВНИМАНИЕ! ВСЕ РАЗДЕЛЫ И ДАННЫЕ НА $TARGET_DEV БУДУТ УНИЧТОЖЕНЫ!"
echo "Для подтверждения введите слово 'ERASE' заглавными буквами:"
read -rp "> " CONFIRM_WORD

if [ "$CONFIRM_WORD" != "ERASE" ]; then
    echo "Установка отменена пользователем."
    exit 0
fi

echo ""
echo "[1/6] Подготовка целевого диска $TARGET_DEV..."
# Размонтирование любых смонтированных разделов целевого накопителя
swapoff -a 2>/dev/null || true
umount -R /mnt/target 2>/dev/null || true
for part in "${TARGET_DEV}"p*; do
    umount "$part" 2>/dev/null || true
done

# Затираем старые заголовки GPT/MBR
dd if=/dev/zero of="$TARGET_DEV" bs=1M count=16 status=none 2>/dev/null || true

echo "[2/6] Создание новой таблицы разделов GPT..."
parted -s "$TARGET_DEV" mklabel gpt
parted -s "$TARGET_DEV" mkpart "M80TA_ESP" fat32 1MiB 513MiB
parted -s "$TARGET_DEV" set 1 esp on
parted -s "$TARGET_DEV" mkpart "M80TA_SYS" btrfs 513MiB 100%

udevadm settle || sleep 2

ESP_PART="${TARGET_DEV}p1"
ROOT_PART="${TARGET_DEV}p2"

echo "[3/6] Форматирование (FAT32 + Btrfs zstd:3 с уникальной меткой M80TA_SYS)..."
mkfs.vfat -F 32 -n "M80TA_ESP" "$ESP_PART"
mkfs.btrfs -f -L "M80TA_SYS" "$ROOT_PART"

echo "[4/6] Создание Btrfs субтомов (@ и @home) и монтирование..."
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

echo "[5/6] Синхронизация файлов системы на внутреннюю eMMC..."
rsync -aAXv --info=progress2 \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / /mnt/target/

echo "[6/6] Настройка UUID, fstab и установка 32-битного UEFI GRUB..."
ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat <<EOF > /mnt/target/etc/fstab
# /etc/fstab: Asus VivoTab Note 8 (M80TA) internal eMMC storage
UUID=$ROOT_UUID  /          btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@      0  0
UUID=$ROOT_UUID  /home      btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@home  0  0
UUID=$ESP_UUID   /boot/efi  vfat   umask=0077                                            0  1
EOF

# Монтирование псевдо-ФС для chroot
mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
mount --bind /run /mnt/target/run

# Установка GRUB без записи в NVRAM в removable fallback путь
chroot /mnt/target grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable
chroot /mnt/target update-grub

# Создание строгого UUID-based первичного загрузчика в ESP
mkdir -p /mnt/target/boot/efi/EFI/BOOT
cat <<EOF > /mnt/target/boot/efi/EFI/BOOT/grub.cfg
# Search strictly by target filesystem UUID to avoid any label collision with USB Live media
search --no-floppy --fs-uuid --set=root $ROOT_UUID
if [ -e (\$root)/@/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/@/boot/grub
    configfile (\$root)/@/boot/grub/grub.cfg
elif [ -e (\$root)/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/boot/grub
    configfile (\$root)/boot/grub/grub.cfg
fi
EOF

# Очистка chroot
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
echo "   УСТАНОВКА НА eMMC УСПЕШНО ЗАВЕРШЕНА!                          "
echo "================================================================="
echo "Теперь вы можете извлечь USB-флешку и перезагрузить планшет."
echo "Он загрузится во внутреннюю память eMMC."
echo ""
read -rp "Перезагрузить планшет сейчас? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    reboot
fi
