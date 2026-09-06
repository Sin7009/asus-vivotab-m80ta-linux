#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Safe eMMC Installer v2.0
#
# Flags:
#   --list     Show detected storage devices and candidates, then exit.
#   --dry-run  Execute all checks, DMI validation, and candidate selection
#              without making any disk modifications.
# ==============================================================================

LIST_ONLY=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --list)
            LIST_ONLY=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            echo "Использование: $0 [--list] [--dry-run]"
            echo "  --list     Показать обнаруженные накопители и статус eMMC"
            echo "  --dry-run  Выполнить все проверки без записи на диск"
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $arg" >&2
            exit 1
            ;;
    esac
done

if [ "$LIST_ONLY" -eq 0 ] && [ "$EUID" -ne 0 ]; then
    echo "Перезапуск с правами root..."
    exec sudo bash "$0" "$@"
fi

TARGET_MOUNTED=0

cleanup() {
    local exit_code=$?
    if [ "$TARGET_MOUNTED" -eq 1 ] && [ -d /mnt/target ]; then
        echo ""
        echo "[*] Очистка и безопасное размонтирование в обратном порядке..."
        set +e
        umount -l /mnt/target/dev/pts 2>/dev/null || true
        umount -l /mnt/target/dev 2>/dev/null || true
        umount -l /mnt/target/proc 2>/dev/null || true
        umount -l /mnt/target/sys 2>/dev/null || true
        umount -l /mnt/target/run 2>/dev/null || true
        umount -l /mnt/target/boot/efi 2>/dev/null || true
        umount -l /mnt/target/home 2>/dev/null || true
        umount -l /mnt/target 2>/dev/null || true
        umount -l /mnt/target_btrfs 2>/dev/null || true
        rmdir /mnt/target_btrfs 2>/dev/null || true
    fi
    if [ $exit_code -ne 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$LIST_ONLY" -eq 0 ]; then
        echo "ВНИМАНИЕ: Установка была прервана или завершилась с ошибкой ($exit_code)!" >&2
        echo "Целевой диск может находиться в частично установленном состоянии." >&2
    fi
}
trap cleanup EXIT INT TERM

clear
echo "================================================================="
echo "   Установщик Debian 13 на внутреннюю eMMC Asus VivoTab (M80TA)  "
[ "$DRY_RUN" -eq 1 ] && echo "   РЕЖИМ ТЕСТИРОВАНИЯ (DRY-RUN): ЗАПИСЬ НА ДИСК ОТКЛЮЧЕНА!      "
echo "================================================================="
echo ""

# 0. Проверка модели устройства через DMI
SYS_MODEL="Unknown"
if [ -f /sys/class/dmi/id/product_name ]; then
    SYS_MODEL=$(cat /sys/class/dmi/id/product_name)
elif command -v dmidecode >/dev/null 2>&1; then
    SYS_MODEL=$(dmidecode -s system-product-name 2>/dev/null || echo "Unknown")
fi
echo "[*] Модель устройства (DMI): ${SYS_MODEL}"
if ! echo "${SYS_MODEL}" | grep -qiE 'M80TA|VivoTab|ASUSTeK'; then
    echo "ПРЕДУПРЕЖДЕНИЕ: DMI-модель не совпадает с Asus M80TA (${SYS_MODEL})."
fi
echo ""

# 1. Определение текущего загрузочного носителя
ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [ -z "$ROOT_SRC" ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось определить источник корневого раздела (findmnt /)!" >&2
    exit 1
fi

# Надежно удаляем Btrfs-суффиксы вида [/@] или [/subvol]
ROOT_SRC_CLEAN=$(echo "$ROOT_SRC" | sed -E 's/\[.*\]//')

BOOTED_DEV=$(lsblk -no PKNAME "$ROOT_SRC_CLEAN" 2>/dev/null || true)
if [ -z "$BOOTED_DEV" ]; then
    BOOTED_DEV=$(echo "$ROOT_SRC_CLEAN" | sed -E 's/p?[0-9]+$//; s|^/dev/||')
fi

if [ -z "$BOOTED_DEV" ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось определить диск текущего загрузочного носителя!" >&2
    exit 1
fi
echo "[*] Текущая система загружена с носителя: /dev/${BOOTED_DEV} (раздел: ${ROOT_SRC_CLEAN})"
echo ""

# 2. Сканирование и строгая фильтрация eMMC устройств
echo "[*] Сканирование накопителей в системе:"
lsblk -o NAME,TYPE,SIZE,RM,RO,TRAN,MODEL,MOUNTPOINTS
echo ""

CANDIDATES=()
for dev_path in /sys/block/*; do
    [ -e "$dev_path" ] || continue
    dev_name=$(basename "$dev_path")

    # Принимаем ТОЛЬКО имена вида ^mmcblk[0-9]+$
    # Отсекаем mmcblk0boot0, mmcblk0boot1, mmcblk0rpmb, sdX, loopX, nvmeX
    if ! [[ "$dev_name" =~ ^mmcblk[0-9]+$ ]]; then
        continue
    fi

    dev_node="/dev/${dev_name}"

    dev_type="UNKNOWN"
    [ -f "${dev_path}/device/type" ] && dev_type=$(cat "${dev_path}/device/type")

    is_removable="1"
    [ -f "${dev_path}/removable" ] && is_removable=$(cat "${dev_path}/removable")

    is_ro="0"
    [ -f "${dev_path}/ro" ] && is_ro=$(cat "${dev_path}/ro")

    size_bytes=0
    if [ -f "${dev_path}/size" ]; then
        size_sectors=$(cat "${dev_path}/size")
        size_bytes=$((size_sectors * 512))
    fi
    size_gb=$(awk "BEGIN {printf \"%.1f\", $size_bytes/1024/1024/1024}")

    hw_name="N/A"
    [ -f "${dev_path}/device/name" ] && hw_name=$(cat "${dev_path}/device/name")

    # Проверка: исключаем загрузочный носитель
    if [ "$dev_name" = "$BOOTED_DEV" ]; then
        echo "[-] Пропуск $dev_node ($size_gb GB): это текущий загрузочный носитель!"
        continue
    fi

    # Проверка: смонтирован ли диск или его разделы
    is_mounted=0
    if findmnt -S "$dev_node" >/dev/null 2>&1 || lsblk -no MOUNTPOINTS "$dev_node" | grep -qv '^$'; then
        is_mounted=1
    fi

    # Проверка использования в swap
    is_swap=0
    if swapon --show | grep -q "$dev_node"; then
        is_swap=1
    fi

    # Критерии для внутренней eMMC планшета:
    # 1. Type == MMC (строго не SD)
    # 2. Removable == 0 (впаянный чип)
    # 3. Read-Only == 0
    # 4. Объем >= 16 GB (17179869184 байт)
    if [ "$dev_type" = "MMC" ] && [ "$is_removable" = "0" ] && [ "$is_ro" = "0" ] && [ "$size_bytes" -ge 17179869184 ]; then
        if [ "$is_mounted" -eq 1 ] || [ "$is_swap" -eq 1 ]; then
            echo "[!] Обнаружена eMMC $dev_node ($size_gb GB, $hw_name), но она сейчас смонтирована или используется как swap!"
        else
            echo "[+] Обнаружена внутренняя eMMC: $dev_node ($size_gb GB, чип: $hw_name)"
            CANDIDATES+=("$dev_node")
        fi
    else
        echo "[?] Устройство $dev_node ($size_gb GB, тип: $dev_type, removable: $is_removable) — не является подходящей eMMC."
    fi
done

echo ""
if [ "$LIST_ONLY" -eq 1 ]; then
    echo "Список кандидатов eMMC:"
    for cand in "${CANDIDATES[@]}"; do
        echo "  -> $cand"
    done
    exit 0
fi

if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Доступная внутренняя eMMC (Type=MMC, RM=0, >=16GB) не найдена!" >&2
    echo "Убедитесь, что система запущена с внешнего USB, а не установлена на планшет." >&2
    exit 1
fi

echo "Найдено кандидатов для установки: ${#CANDIDATES[@]}"
for cand in "${CANDIDATES[@]}"; do
    echo "  -> $cand"
done
echo ""

echo "-----------------------------------------------------------------"
echo "ТРЕБУЕТСЯ ТОЧНОЕ ПОДТВЕРЖДЕНИЕ!"
echo "Введите полный путь к целевому накопителю для установки (например, ${CANDIDATES[0]}):"
read -rp "Целевой диск > " USER_INPUT_DEV

TARGET_DEV=""
for cand in "${CANDIDATES[@]}"; do
    if [ "$USER_INPUT_DEV" = "$cand" ]; then
        TARGET_DEV="$cand"
        break
    fi
done

if [ -z "$TARGET_DEV" ]; then
    echo "ОШИБКА: Введенное имя '$USER_INPUT_DEV' не совпадает ни с одним проверенным eMMC!" >&2
    exit 1
fi

echo ""
echo "ВНИМАНИЕ! ВСЕ ДАННЫЕ НА ДИСКЕ $TARGET_DEV БУДУТ БЕЗВОЗВРАТНО СТЕРТЫ!"
echo "Для подтверждения уничтожения данных введите 'CONFIRM_DESTROY':"
read -rp "Подтверждение > " CONFIRM_WORD

if [ "$CONFIRM_WORD" != "CONFIRM_DESTROY" ]; then
    echo "Установка отменена пользователем."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "================================================================="
    echo "DRY-RUN ЗАВЕРШЕН УСПЕШНО!"
    echo "Все аппаратные критерии валидированы для $TARGET_DEV."
    echo "Никаких изменений на диск внесено не было."
    echo "================================================================="
    exit 0
fi

TARGET_MOUNTED=1

echo ""
echo "[1/7] Безопасная очистка целевого диска $TARGET_DEV (wipefs + sgdisk)..."
swapoff -a 2>/dev/null || true
for part in "${TARGET_DEV}"p*; do
    [ -e "$part" ] && umount "$part" 2>/dev/null || true
done

wipefs -a "$TARGET_DEV"
sgdisk --zap-all "$TARGET_DEV"

echo "[2/7] Создание таблицы разделов GPT..."
parted -s "$TARGET_DEV" mklabel gpt
parted -s "$TARGET_DEV" mkpart "M80TA_ESP" fat32 1MiB 513MiB
parted -s "$TARGET_DEV" set 1 esp on
parted -s "$TARGET_DEV" mkpart "M80TA_SYS" btrfs 513MiB 100%

udevadm settle || sleep 2

ESP_PART="${TARGET_DEV}p1"
ROOT_PART="${TARGET_DEV}p2"

echo "[3/7] Форматирование (FAT32 + Btrfs со сжатием zstd:3, метка M80TA_SYS)..."
mkfs.vfat -F 32 -n "M80TA_ESP" "$ESP_PART"
mkfs.btrfs -f -L "M80TA_SYS" "$ROOT_PART"

echo "[4/7] Создание Btrfs субтомов (@ и @home) и монтирование..."
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

echo "[5/7] Копирование системы на eMMC (rsync)..."
rsync -aAX --info=progress2 \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / /mnt/target/

echo "[6/7] Сброс идентификаторов Live-системы на целевой eMMC..."
truncate -s 0 /mnt/target/etc/machine-id
rm -f /mnt/target/var/lib/dbus/machine-id
rm -f /mnt/target/var/lib/systemd/random-seed
rm -f /mnt/target/etc/ssh/ssh_host_*
rm -f /mnt/target/var/lib/m80ta-firstboot.done

echo "[7/7] Настройка GRUB (IA32) и UUID-based загрузки..."
ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat <<EOF > /mnt/target/etc/fstab
# /etc/fstab: Asus VivoTab Note 8 (M80TA) internal eMMC storage
UUID=$ROOT_UUID  /          btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@      0  0
UUID=$ROOT_UUID  /home      btrfs  noatime,compress=zstd:3,space_cache=v2,subvol=@home  0  0
UUID=$ESP_UUID   /boot/efi  vfat   umask=0077                                            0  1
EOF

mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
mount --bind /run /mnt/target/run

chroot /mnt/target grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable
chroot /mnt/target update-initramfs -u -k all
chroot /mnt/target update-grub

mkdir -p /mnt/target/boot/efi/EFI/BOOT
cat <<EOF > /mnt/target/boot/efi/EFI/BOOT/grub.cfg
# Search strictly by target eMMC root partition UUID
search --no-floppy --fs-uuid --set=root $ROOT_UUID
if [ -e (\$root)/@/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/@/boot/grub
    configfile (\$root)/@/boot/grub/grub.cfg
elif [ -e (\$root)/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/boot/grub
    configfile (\$root)/boot/grub/grub.cfg
fi
EOF

# Проверяем и при необходимости генерируем автономный загрузчик
if [ ! -s /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI ]; then
    chroot /mnt/target grub-mkstandalone \
        -O i386-efi \
        -o /boot/efi/EFI/BOOT/BOOTIA32.EFI \
        -d /usr/lib/grub/i386-efi/ \
        --modules="part_gpt part_msdos fat btrfs normal search search_fs_uuid search_label linux" \
        "/boot/grub/grub.cfg=/boot/efi/EFI/BOOT/grub.cfg"
fi

# ВЕРИФИКАЦИЯ:
test -s /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI || {
    echo "КРИТИЧЕСКАЯ ОШИБКА: BOOTIA32.EFI пуст или отсутствует!" >&2
    exit 1
}

if command -v file >/dev/null 2>&1; then
    file /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI | grep -qiE 'PE32|EFI' || {
        echo "КРИТИЧЕСКАЯ ОШИБКА: BOOTIA32.EFI не является исполняемым файлом EFI PE32!" >&2
        exit 1
    }
fi

test -s /mnt/target/boot/efi/EFI/BOOT/grub.cfg || {
    echo "КРИТИЧЕСКАЯ ОШИБКА: grub.cfg в ESP пуст или отсутствует!" >&2
    exit 1
}

grep -q "$ROOT_UUID" /mnt/target/boot/efi/EFI/BOOT/grub.cfg || {
    echo "КРИТИЧЕСКАЯ ОШИБКА: grub.cfg не содержит UUID целевого раздела!" >&2
    exit 1
}

echo "[*] Синхронизация буферов диска..."
sync

echo ""
echo "================================================================="
echo "   УСТАНОВКА НА eMMC УСПЕШНО ЗАВЕРШЕНА И ВЕРИФИЦИРОВАНА!        "
echo "   Загрузчик: BOOTIA32.EFI ($(stat -c %s /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI 2>/dev/null || stat -f %z /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI) байт, PE32) "
echo "   UUID:      $ROOT_UUID                                        "
echo "================================================================="
echo "Извлеките USB-флешку и перезагрузите планшет."
echo ""
read -rp "Перезагрузить планшет сейчас? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    reboot
fi
