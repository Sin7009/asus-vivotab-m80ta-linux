# Debian 13 (Trixie) for ASUS VivoTab Note 8 (M80TA)

Специализированный дистрибутив на базе **Debian 13 (Trixie) amd64** в формате **загрузочного persistent raw-образа (.img.xz)** для планшета **ASUS VivoTab Note 8 (M80TA)**.

Проект нацелен на создание автономного цифрового блокнота со стилусом Wacom EMR и компактного терминала удаленного мониторинга.

---

## ⚡ Статус поддержки аппаратных функций

> [!NOTE]
> Все программные компоненты сконфигурированы в образе, но их фактическая работоспособность на конкретном экземпляре M80TA требует проверки по чеклисту [TESTING.md](TESTING.md).

| Функция / Узел | Статус в текущем билде | Примечание |
| :--- | :---: | :--- |
| **32-битный UEFI (IA32) + 64-бит CPU** | `РАБОТАЕТ` | Автономный `grub-efi-ia32` (`BOOTIA32.EFI`) с флагами `--no-nvram --removable` для защиты NVRAM. |
| **Защита от Bay Trail C-state бага** | `РАБОТАЕТ` | По умолчанию включен режим ядра `intel_idle.max_cstate=1` (в меню GRUB доступен выбор Normal-режима). |
| **Wacom EMR стилус** | `РАБОТАЕТ` | Сессия Plasma Mobile / Desktop (Wayland), стек `libinput`, поддержка силы нажима пера и palm rejection. |
| **Экран 800×1280 и акселерометр** | `РАБОТАЕТ` | `fbcon=rotate:1` для tty; `iio-sensor-proxy` и KWin автоповорот экрана и дигитайзера. |
| **Физические клавиши и кнопка Windows** | `РАБОТАЕТ` | Громкость (+/-), питание, блокировка поворота (`soc_button_array`). Сенсорная кнопка Windows переназначена на `KEY_LEFTMETA` (udev hwdb). |
| **Звук Intel SST (ALC5640)** | `РАБОТАЕТ` | Стереодинамики и наушники через PipeWire 1.4.2 / WirePlumber и Realtek `bytcr-rt5640`. |
| **Wi-Fi и Bluetooth (Broadcom)** | `РАБОТАЕТ` | Broadcom `BCM43241` (5 ГГц, линк 270 Мбит/с) и Bluetooth контроллер с прошивкой `BCM4324B3.hcd`. |
| **KDE Plasma & Набор приложений** | `РАБОТАЕТ` | Plasma Mobile + KDE Plasma Desktop, Dolphin, System Settings, Discover, Konsole, Kate, Spectacle, Xournal++, MyPaint, Foliate, Haruna, Okular. |
| **Firefox ESR & Веб-серфинг** | `РАБОТАЕТ` | Нативный Wayland (`MOZ_ENABLE_WAYLAND=1`), сенсорная оптимизация, кинетическая прокрутка и масштабирование. |
| **Экранная клавиатура Maliit** | `РАБОТАЕТ` | Двуязычная (EN + RU), исправлена опечатка upstream в QML, добавлены масштабируемые векторные иконки (Shift, Backspace, Enter, Language, Space). |
| **Камеры (Intel IPU2 / AtomISP)** | `EXPERIMENTAL` | Драйверы atomisp в ядре 6.12 включены, но стабильность захвата видео не гарантируется. |

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
