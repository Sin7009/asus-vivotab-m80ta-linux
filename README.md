# Debian 13 (Trixie) for ASUS VivoTab Note 8 (M80TA)

Специализированный дистрибутив на базе **Debian 13 (Trixie) amd64** в формате **загрузочного persistent raw-образа (.img.xz)** для планшета **ASUS VivoTab Note 8 (M80TA)**.

Проект нацелен на создание автономного цифрового блокнота со стилусом Wacom EMR и компактного терминала удаленного мониторинга.

---

## ⚡ Статус поддержки аппаратных функций

> [!NOTE]
> Все программные компоненты сконфигурированы в образе, но их фактическая работоспособность на конкретном экземпляре M80TA требует проверки по чеклисту [TESTING.md](TESTING.md).

| Функция / Узел | Статус в текущем билде | Примечание |
| :--- | :---: | :--- |
| **32-битный UEFI (IA32) + 64-бит CPU** | `СКОНФИГУРИРОВАНО` | Автономный `grub-efi-ia32` (`BOOTIA32.EFI`) с флагами `--no-nvram --removable` для защиты NVRAM. |
| **Защита от Bay Trail C-state бага** | `СКОНФИГУРИРОВАНО` | По умолчанию включен режим ядра `intel_idle.max_cstate=1` (в меню GRUB доступен выбор Normal-режима). |
| **Wacom EMR стилус и тачскрин** | `СКОНФИГУРИРОВАНО` | Сессия Plasma Mobile (Wayland), стек `libinput` и предустановленный `xournalpp`. |
| **Экран 800×1280 и акселерометр** | `СКОНФИГУРИРОВАНО` | `fbcon=rotate:1` для tty; `iio-sensor-proxy` для автоповорота рабочего стола и дигитайзера. |
| **Звук Intel SST (ALC5640)** | `UNTESTED` | Установлены `firmware-intel-sound` (`fw_sst_0f28.bin`), `alsa-ucm-conf` и PipeWire/WirePlumber. |
| **Wi-Fi и Bluetooth (Broadcom)** | `UNTESTED` | Установлены `wpasupplicant`, `wireless-regdb`, `firmware-brcm80211`. Фактическая ревизия чипа уточняется по dmesg. |
| **Камеры (Intel IPU2 / AtomISP)** | `EXPERIMENTAL` | Драйверы atomisp в ядре 6.12 включены, но стабильность захвата видео не гарантируется. |
| **Одновременная зарядка и OTG** | `ТРЕБУЕТ ЖЕЛЕЗА` | Требуется аппаратный OTG Y-кабель с поддержкой ACA-режима (Accessory Charger Adapter). |

---

## ⚠️ ВАЖНО ПЕРЕД НАЧАЛОМ

### 1. Отключение Secure Boot в BIOS
Кастомный 32-битный загрузчик `BOOTIA32.EFI` не содержит цифровой подписи Microsoft, поэтому планшет с включенным Secure Boot загружаться откажется:
1. Подключите USB-клавиатуру к планшету через OTG-хаб.
2. При включении удерживайте клавишу `Esc` или `F2` (либо зажмите `Volume Down` + `Power` и выберите вход в Setup).
3. Перейдите в раздел **Security** -> **Secure Boot Configuration**.
4. Установите **Secure Boot** в положение **Disabled**.
5. Нажмите `F10` для сохранения настроек и перезагрузки.

### 2. Обязательный бэкап Windows и DriverStore
Перед стиранием внутренней eMMC:
- Создайте полный посекторный образ внутренней памяти планшета.
- **Как минимум сохраните каталог `C:\Windows\System32\DriverStore`**: в нем находятся уникальные для фабричной калибровки M80TA файлы NVRAM для Wi-Fi (`brcmfmac43340-sdio.txt`), которые могут отсутствовать в общем пакете `firmware-brcm80211`.

---

## 🔑 Учетные данные и доступ по SSH

Сборка поддерживает два профиля:
- **`personal-debug`** (по умолчанию для личных сборок):
  - SSH и mDNS включены сразу при старте.
  - Вход разрешен **ИСКЛЮЧИТЕЛЬНО по SSH-ключу** пользователя.
  - Парольная аутентификация и прямой вход root отключены (`PasswordAuthentication no`, `PermitRootLogin no`).
  - Пароль root заблокирован (`passwd -l root`).
  - Для пользователя `vivotab` разрешен `NOPASSWD:ALL` в sudo для бесшовной удаленной отладки.
  - Уникальные SSH host keys и `machine-id` генерируются при первом включении планшета службой `m80ta-firstboot.service`.
- **`public`**:
  - Без предустановленных личных ключей и паролей.
  - SSH выключен по умолчанию.
  - Sudo требует ввода пароля.

Подключение по SSH:
```bash
ssh-keygen -R vivotab-m80ta.local 2>/dev/null
ssh vivotab@vivotab-m80ta.local
```

---

## 🚀 Запись и первый запуск

1. Запишите образ на USB-флешку от 8 ГБ через **BalenaEtcher**, **Raspberry Pi Imager** или консоль:
   ```bash
   xz -dc m80ta-debian13-*.img.xz | sudo dd of=/dev/rdiskX bs=4M status=progress conv=fsync
   ```
2. Подключите накопитель через Micro-USB OTG.
3. Зажмите кнопку **Уменьшения громкости (Volume Down)** и, удерживая её, нажмите **Включение (Power)**.
4. Выберите USB-накопитель в меню UEFI.
5. Выполните аппаратное тестирование по чеклисту в файле [TESTING.md](TESTING.md).

### Сбор диагностического отчета в один клик
После первой загрузки соберите полный диагностический отчет о железе:
```bash
sudo /usr/local/bin/m80ta-collect-debug
```
Скрипт создаст архив `~/m80ta-debug-YYYYMMDD-HHMMSS.tar.gz` со всеми логами ядра, шин, аудио и сенсоров.

---

## 💾 Установка на внутреннюю память (eMMC)

Скрипт `install-to-emmc` реализует многоуровневую защиту от случайного повреждения накопителей:
- Запуск без модификаций (тест критериев обнаружения):
  ```bash
  sudo /usr/local/bin/install-to-emmc --dry-run
  ```
- Просмотр найденных чипов:
  ```bash
  sudo /usr/local/bin/install-to-emmc --list
  ```
- Реальная установка:
  ```bash
  sudo /usr/local/bin/install-to-emmc
  ```
  Скрипт проверит, что устройство имеет тип `MMC`, является впаянным (`removable=0`), доступно на запись, имеет объем >= 16 ГБ и **не является текущим загрузочным диском**. Для подтверждения стирания потребуется ввести точный путь накопителя (например, `/dev/mmcblk0`) и контрольное слово `CONFIRM_DESTROY`.

После копирования скрипт автоматически сбрасывает `machine-id` и SSH host keys на целевом накопителе, чтобы установленная система получила свежие уникальные идентификаторы.

---

## 🏗 Сборка образа с нуля

Сборка полностью воспроизводима в среде Docker:

```bash
git clone https://github.com/Sin7009/asus-vivotab-m80ta-linux.git
cd asus-vivotab-m80ta-linux

# 1. Поместите ваш публичный SSH-ключ:
cp ~/.ssh/id_ed25519.pub files/authorized_keys

# 2. (Опционально) Настройте домашний Wi-Fi для автоподключения:
# cp files/m80ta-wifi.nmconnection.example files/m80ta-wifi.nmconnection
# nano files/m80ta-wifi.nmconnection

# 3. Запуск сборки personal-debug профиля:
sudo ./build/run-docker.sh

# Для сборки нейтрального публичного релиза:
# BUILD_PROFILE=public sudo ./build/run-docker.sh
```

Готовый образ и его контрольная сумма будут сформированы в каталоге `output/`.
