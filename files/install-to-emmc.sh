#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Safe eMMC Installer v1.1
# Fully verified hardware checks:
# - Strict regex filtering: ^mmcblk[0-9]+$ (ignoring boot0/boot1/rpmb partitions)
# - Hardware attributes: Type=MMC, Removable=0, ReadOnly=0, Size >= 16GB
# - Detection of booted device to prevent self-destruction
# - Cleans machine-id and SSH host keys on target to prevent cloned identities
# - Verifies non-empty BOOTIA32.EFI bootloader after installation
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Перезапуск с правами root..."
    exec sudo bash "$0" "$@"
fi

cleanup() {
    local exit_code=$?
    if [ -d /mnt/target ]; then
        echo ""
        echo "[*] Очистка и размонтирование временных точек монтирования..."
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
    if [ $exit_code -ne 0 ]; then
        echo "ВНИМАНИЕ: Скрипт установки завершился с ошибкой (код $exit_code)!" >&2
    fi
}
trap cleanup EXIT

clear
echo "================================================================="
echo "   Безопасная установка Debian 13 на внутреннюю eMMC Asus M80TA "
echo "================================================================="
echo ""

# 1. Определение текущего загрузочного носителя
ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [ -z "$ROOT_SRC" ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось определить исходный корневой раздел (findmnt /)!" >&2
    exit 1
fi

BOOTED_DEV=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)
if [ -z "$BOOTED_DEV" ]; then
    BOOTED_DEV=$(echo "$ROOT_SRC" | sed -E 's/p?[0-9]+$//; s|^/dev/||')
fi

if [ -z "$BOOTED_DEV" ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось определить родительский диск загрузочного носителя!" >&2
    exit 1
fi
echo "[*] Текущая система работает с накопителя: /dev/${BOOTED_DEV}"
echo ""

# 2. Сканирование и фильтрация накопителей
echo "[*] Доступные блочные устройства в системе:"
lsblk -o NAME,TYPE,SIZE,RM,RO,TRAN,MOUNTPOINTS
echo ""

CANDIDATES=()
for dev_path in /sys/block/*; do
    [ -e "$dev_path" ] || continue
    dev_name=$(basename "$dev_path")

    # Строгое регулярное выражение: только основные блочные mmcblk устройства (^mmcblk[0-9]+$)
    # Исключает mmcblk0boot0, mmcblk0boot1, mmcblk0rpmb, loop-устройства и т.д.
    if ! [[ "$dev_name" =~ ^mmcblk[0-9]+$ ]]; then
        continue
    fi

    dev_node="/dev/${dev_name}"

    # Проверка типа устройства в mmc подсистеме
    dev_type="UNKNOWN"
    if [ -f "${dev_path}/device/type" ]; then
        dev_type=$(cat "${dev_path}/device/type")
    fi

    # Проверка съемности (0 = non-removable, 1 = removable)
    is_removable="1"
    if [ -f "${dev_path}/removable" ]; then
        is_removable=$(cat "${dev_path}/removable")
    fi

    # Проверка режима только для чтения (0 = read-write, 1 = read-only)
    is_ro="0"
    if [ -f "${dev_path}/ro" ]; then
        is_ro=$(cat "${dev_path}/ro")
    fi

    # Проверка размера в байтах (eMMC M80TA имеет объем 32 или 64 ГБ, минимум 16 ГБ)
    size_bytes=0
    if [ -f "${dev_path}/size" ]; then
        size_sectors=$(cat "${dev_path}/size")
        size_bytes=$((size_sectors * 512))
    fi
    size_gb=$(awk "BEGIN {printf \"%.1f\", $size_bytes/1024/1024/1024}")

    hw_name="N/A"
    if [ -f "${dev_path}/device/name" ]; then
        hw_name=$(cat "${dev_path}/device/name")
    fi

    # Исключаем устройство, с которого загружена текущая система
    if [ "$dev_name" = "$BOOTED_DEV" ]; then
        echo "[-] Пропуск $dev_node ($size_gb GB): это текущий загрузочный носитель!"
        continue
    fi

    # Проверка требований к eMMC:
    # 1. Type == MMC (не SD)
    # 2. Removable == 0 (впаянная память)
    # 3. Read-Only == 0
    # 4. Объем >= 16 GB
    if [ "$dev_type" = "MMC" ] && [ "$is_removable" = "0" ] && [ "$is_ro" = "0" ] && [ "$size_bytes" -ge 17179869184 ]; then
        echo "[+] Обнаружена внутренняя eMMC: $dev_node ($size_gb GB, чип: $hw_name)"
        CANDIDATES+=("$dev_node")
    else
        echo "[?] Устройство $dev_node ($size_gb GB, тип: $dev_type, removable: $is_removable, ro: $is_ro) не соответствует критериям внутренней eMMC!"
    fi
done

echo ""
if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Подходящая внутренняя eMMC (Type=MMC, RM=0, >=16GB) не обнаружена!" >&2
    echo "Убедитесь, что система запущена с внешнего USB, а не установлена на планшет." >&2
    exit 1
fi

echo "Найдено подходящих кандидатов на eMMC: ${#CANDIDATES[@]}"
for dev in "${CANDIDATES[@]}"; do
    echo "  -> $dev"
done
echo ""

echo "-----------------------------------------------------------------"
echo "ТРЕБУЕТСЯ ЯВНОЕ ПОДТВЕРЖДЕНИЕ!"
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
    echo "ОШИБКА: Введенный диск '$USER_INPUT_DEV' не входит в список проверенных eMMC!" >&2
    exit 1
fi

echo ""
echo "ВНИМАНИЕ! ВСЕ РАЗДЕЛЫ И ДАННЫЕ НА $TARGET_DEV БУДУТ БЕЗВОЗВРАТНО СТЕРТЫ!"
echo "Для подтверждения уничтожения данных введите 'CONFIRM_DESTROY':"
read -rp "Подтверждение > " CONFIRM_WORD

if [ "$CONFIRM_WORD" != "CONFIRM_DESTROY" ]; then
    echo "Установка отменена пользователем."
    exit 0
fi

echo ""
echo "[1/7] Подготовка целевого диска $TARGET_DEV..."
# Размонтирование любых активных разделов целевого накопителя
swapoff -a 2>/dev/null || true
for part in "${TARGET_DEV}"p*; do
    [ -e "$part" ] && umount "$part" 2>/dev/null || true
done

# Затираем заголовки GPT/MBR и проверяем успешность
dd if=/dev/zero of="$TARGET_DEV" bs=1M count=16 status=none

echo "[2/7] Создание новой таблицы разделов GPT..."
parted -s "$TARGET_DEV" mklabel gpt
parted -s "$TARGET_DEV" mkpart "M80TA_ESP" fat32 1MiB 513MiB
parted -s "$TARGET_DEV" set 1 esp on
parted -s "$TARGET_DEV" mkpart "M80TA_SYS" btrfs 513MiB 100%

udevadm settle || sleep 2

ESP_PART="${TARGET_DEV}p1"
ROOT_PART="${TARGET_DEV}p2"

echo "[3/7] Форматирование (FAT32 + Btrfs zstd:3, метка M80TA_SYS)..."
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

echo "[5/7] Синхронизация файлов системы на внутреннюю eMMC..."
rsync -aAXv --info=progress2 \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / /mnt/target/

echo "[6/7] Очистка идентификаторов Live-системы (machine-id и SSH host keys)..."
# Гарантируем, что установленная eMMC получит уникальные ключи и machine-id
truncate -s 0 /mnt/target/etc/machine-id
rm -f /mnt/target/etc/ssh/ssh_host_*
rm -f /mnt/target/var/lib/m80ta-firstboot.done

echo "[7/7] Настройка UUID, fstab и установка 32-битного UEFI GRUB..."
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

# Установка GRUB без записи в NVRAM
chroot /mnt/target grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable
chroot /mnt/target update-grub

# Создание первичного grub.cfg с явным поиском по UUID раздела eMMC
mkdir -p /mnt/target/boot/efi/EFI/BOOT
cat <<EOF > /mnt/target/boot/efi/EFI/BOOT/grub.cfg
# Search strictly by target eMMC root UUID to eliminate USB label collisions
search --no-floppy --fs-uuid --set=root $ROOT_UUID
if [ -e (\$root)/@/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/@/boot/grub
    configfile (\$root)/@/boot/grub/grub.cfg
elif [ -e (\$root)/boot/grub/grub.cfg ]; then
    set prefix=(\$root)/boot/grub
    configfile (\$root)/boot/grub/grub.cfg
fi
EOF

# ВЕРИФИКАЦИЯ ЗАГРУЗЧИКА: проверяем, что BOOTIA32.EFI существует и не пуст!
if [ ! -s /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI ]; then
    echo "ВНИМАНИЕ: BOOTIA32.EFI отсутствует, генерируем через grub-mkstandalone..."
    chroot /mnt/target grub-mkstandalone \
        -O i386-efi \
        -o /boot/efi/EFI/BOOT/BOOTIA32.EFI \
        -d /usr/lib/grub/i386-efi/ \
        --modules="part_gpt part_msdos fat btrfs normal search search_fs_uuid search_label linux" \
        "/boot/grub/grub.cfg=/boot/efi/EFI/BOOT/grub.cfg"
fi

test -s /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI || {
    echo "КРИТИЧЕСКАЯ ОШИБКА: Файл BOOTIA32.EFI не создан или пуст!" >&2
    exit 1
}

test -s /mnt/target/boot/efi/EFI/BOOT/grub.cfg || {
    echo "КРИТИЧЕСКАЯ ОШИБКА: Файл grub.cfg в ESP не создан или пуст!" >&2
    exit 1
}

echo ""
echo "================================================================="
echo "   УСТАНОВКА НА eMMC УСПЕШНО ЗАВЕРШЕНА И ВЕРИФИЦИРОВАНА!        "
echo "   Загрузчик: BOOTIA32.EFI ($(stat -c %s /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI 2>/dev/null || stat -f %z /mnt/target/boot/efi/EFI/BOOT/BOOTIA32.EFI) байт) "
echo "================================================================="
echo "Извлеките USB-флешку и перезагрузите планшет."
echo ""
read -rp "Перезагрузить планшет сейчас? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    reboot
fi
