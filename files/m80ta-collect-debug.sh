#!/bin/bash
set -euo pipefail

# ==============================================================================
# ASUS VivoTab Note 8 (M80TA) - Hardware Diagnostic Collector
# Gathers all logs, kernel traces, audio states, input devices, and DMI data.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Перезапуск с правами root для сбора полной системной информации..."
    exec sudo bash "$0" "$@"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEBUG_DIR="/tmp/m80ta-debug-${TIMESTAMP}"
ARCHIVE_PATH="/home/vivotab/m80ta-debug-${TIMESTAMP}.tar.gz"

echo "=== Сбор диагностической информации Asus M80TA ==="
mkdir -p "${DEBUG_DIR}"

echo "[1/15] Журналы systemd и dmesg..."
journalctl -b --no-pager > "${DEBUG_DIR}/journalctl-boot.log" 2>&1 || true
dmesg > "${DEBUG_DIR}/dmesg.log" 2>&1 || true
dmesg | grep -iE 'firmware|error|fail|warn|bcm|atomisp|sst|wacom|goodix|bytcr|intel' > "${DEBUG_DIR}/dmesg-hardware-filtered.log" 2>&1 || true

echo "[2/15] DMI и модель оборудования..."
dmidecode > "${DEBUG_DIR}/dmidecode.txt" 2>&1 || true
cat /sys/class/dmi/id/* > "${DEBUG_DIR}/dmi-sysfs.txt" 2>/dev/null || true

echo "[3/15] Блочные устройства и накопители..."
lsblk -o NAME,TYPE,SIZE,ROTA,RM,RO,TRAN,MODEL,FSTYPE,UUID,MOUNTPOINTS > "${DEBUG_DIR}/lsblk.txt" 2>&1 || true
findmnt -l > "${DEBUG_DIR}/findmnt.txt" 2>&1 || true
fdisk -l > "${DEBUG_DIR}/fdisk.txt" 2>&1 || true
for mmc in /sys/block/mmcblk*; do
    if [ -d "$mmc" ]; then
        echo "=== $mmc ===" >> "${DEBUG_DIR}/mmc-info.txt"
        udevadm info -p "$mmc" >> "${DEBUG_DIR}/mmc-info.txt" 2>&1 || true
        for attr in type name cid csd ocr date rev serial; do
            [ -f "$mmc/device/$attr" ] && echo "$attr: $(cat "$mmc/device/$attr")" >> "${DEBUG_DIR}/mmc-info.txt" || true
        done
    fi
done

echo "[4/15] PCI и USB шины..."
lspci -nnk > "${DEBUG_DIR}/lspci.txt" 2>&1 || true
lsusb > "${DEBUG_DIR}/lsusb.txt" 2>&1 || true
lsusb -v > "${DEBUG_DIR}/lsusb-verbose.txt" 2>&1 || true

echo "[5/15] Сеть и беспроводные интерфейсы..."
ip addr > "${DEBUG_DIR}/ip-addr.txt" 2>&1 || true
ip route > "${DEBUG_DIR}/ip-route.txt" 2>&1 || true
rfkill list all > "${DEBUG_DIR}/rfkill.txt" 2>&1 || true
iw dev > "${DEBUG_DIR}/iw-dev.txt" 2>&1 || true
nmcli device status > "${DEBUG_DIR}/nmcli-devices.txt" 2>&1 || true

echo "[6/15] Звуковая подсистема (PipeWire, ALSA, UCM)..."
aplay -l > "${DEBUG_DIR}/aplay-devices.txt" 2>&1 || true
arecord -l > "${DEBUG_DIR}/arecord-devices.txt" 2>&1 || true
wpctl status > "${DEBUG_DIR}/wpctl-status.txt" 2>&1 || true
pactl info > "${DEBUG_DIR}/pactl-info.txt" 2>&1 || true
pactl list sinks > "${DEBUG_DIR}/pactl-sinks.txt" 2>&1 || true
cat /proc/asound/cards > "${DEBUG_DIR}/asound-cards.txt" 2>&1 || true

echo "[7/15] Устройства ввода и Wacom перо..."
libinput list-devices > "${DEBUG_DIR}/libinput-devices.txt" 2>&1 || true
cat /proc/bus/input/devices > "${DEBUG_DIR}/input-devices.txt" 2>&1 || true

echo "[8/15] Сенсоры и автоповорот (проверка за 3 сек)..."
timeout 3 monitor-sensor > "${DEBUG_DIR}/monitor-sensor.txt" 2>&1 || true

echo "[9/15] Питание и батарея..."
upower -d > "${DEBUG_DIR}/upower.txt" 2>&1 || true
for ps in /sys/class/power_supply/*; do
    if [ -d "$ps" ]; then
        echo "=== $(basename "$ps") ===" >> "${DEBUG_DIR}/power-supply.txt"
        udevadm info -p "$ps" >> "${DEBUG_DIR}/power-supply.txt" 2>&1 || true
    fi
done

echo "[10/15] Загруженные модули ядра..."
lsmod > "${DEBUG_DIR}/lsmod.txt" 2>&1 || true

echo "[11/15] Статус Secure Boot..."
mokutil --sb-state > "${DEBUG_DIR}/secureboot.txt" 2>&1 || true

echo "[12/15] Упаковка в архив..."
tar -czf "${ARCHIVE_PATH}" -C /tmp "m80ta-debug-${TIMESTAMP}"
rm -rf "${DEBUG_DIR}"
chown 1000:1000 "${ARCHIVE_PATH}"

echo ""
echo "================================================================="
echo "Диагностический архив успешно сформирован:"
echo "-> ${ARCHIVE_PATH} ($(stat -c %s "${ARCHIVE_PATH}" 2>/dev/null || stat -f %z "${ARCHIVE_PATH}") байт)"
echo "================================================================="
echo "Вы можете скопировать этот файл по SSH:"
echo "scp vivotab@vivotab-m80ta.local:${ARCHIVE_PATH} ./"
