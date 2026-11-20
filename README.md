# initish — ядро и образ для Lenovo IdeaPad Slim 5 14Q8X9 (83HL)

Репозиторий-сборочница: собирает **модифицированное ядро linux-83hl** под
Snapdragon X Plus X1P42100 и **готовый образ диска** (не установщик), который
раскатывается на NVMe ноутбука одной командой. Всё выкладывается в GitHub Release.

Ядро берётся из [jglathe/linux_ms_dev_kit](https://github.com/jglathe/linux_ms_dev_kit)
(ветка `jg/ubuntu-qcom-x1e-7.2.y`) — там уже есть рабочий DTS для 83HL.
Что известно про звук, GPU, прошивки и сон: [docs/83hl-linux.md](docs/83hl-linux.md).

```
push tag v*  ──►  kernel job  ──►  image job  ──►  release
                  (cross-clang)    (ALARM+qemu)    (ядро + .img.zst + sha256)
```

## Железо (из дампа `../83`)

| | |
|---|---|
| модель | IdeaPad Slim 5 14Q8X9, machine type **83HL** |
| SoC | Snapdragon **X Plus X1P42100** (Oryon), 32 ГБ |
| GPU | Adreno **X1-45** (`msm`) |
| Wi-Fi / BT | FastConnect **7800**, PCI `17cb:1107` / `17cb:0111` → `ath12k`, `hci_qca` |
| NVMe | Samsung MZAL81T0HDLB, PCI `144D:A80D` |
| BIOS | PUCN52WW, SMBIOS 3.6 |
| ACPI | DSDT 335 КБ в `../83/acpi/registry/DSDT_00000003_00000000.bin` |

Подробнее — [docs/hardware.md](docs/hardware.md).

## Что собирается

1. **Ядро** `linux-83hl-<ver>-arm64.tar.zst`:
   `Image`, `lib/modules/<ver>`, `boot/dtbs/<ver>`, `.config`, `System.map`.
2. **Образ** `arch-83hl.img.zst` — GPT: `ESP` (FAT32, 512 МиБ, UKI
   `\EFI\BOOT\BOOTAA64.EFI` с ядром, initramfs и **DTB внутри**) +
   `arch83hl` (ext4, весь остаток).
   Внутри — Arch Linux ARM (aarch64), systemd, NetworkManager, sshd,
   автологин root на tty1 и юнит `growroot`, который при первом бусте
   растягивает раздел на весь диск.
3. `SHA256SUMS`, `IMAGE_INFO.txt`.

## Как запустить сборку

Только вручную: GitHub → **Actions** → **build-83hl** → *Run workflow*
(ветка `main`). Поля:

| поле | смысл |
|---|---|
| `kernel_repo` | git-URL ядра (пусто — jglathe/linux_ms_dev_kit) |
| `kernel_ref` | ветка/тег/коммит (пусто — jg/ubuntu-qcom-x1e-7.2.y) |
| `dtb` | какой DTB зашить в UKI (пусто — slim5x-oled) |
| `firmware_url` | `.tar.gz` с прошивками (пусто — переменная `FIRMWARE_URL`) |
| `image_size` | размер образа до growroot (по умолчанию `6G`) |
| `release_tag` | если заполнить, например `v0.1.0`, — создать GitHub Release |
| `skip_release` | собрать без публикации |

Без `release_tag` ядро и образ остаются только в артефактах запуска
(14 дней). Автоматического запуска по тегам нет.

### Переменные репозитория (Settings → Variables)

| переменная | по умолчанию | смысл |
|---|---|---|
| `KERNEL_REPO` | `jglathe/linux_ms_dev_kit` | git-URL ядра |
| `KERNEL_REF` | `jg/ubuntu-qcom-x1e-7.2.y` | ветка/тег/коммит |
| `KDEFCONFIG` | `ubuntu_x1e_defconfig` | имя defconfig / путь к `.config` |
| `DTB` | `qcom/x1p42100-lenovo-ideapad-slim5x-oled.dtb` | ожидаемый dtb |
| `FIRMWARE_URL` | — | `.tar.gz` с прошивками ADSP/CDSP/GPU |
| `IMAGE_SIZE` | `6G` | размер образа до growroot |
| `EXTRA_PKGS` | — | доп. пакеты pacman в образ |

Ядро можно положить и сабмодулем: `git submodule add <url> kernel`.

## Куда класть свой порт

```
dts/        *.dts / *.dtsi  — копируются в arch/arm64/boot/dts/qcom/
                              и автоматически добавляются в Makefile
patches/    *.patch         — применяются git apply -p1 по порядку имён
config/     kernel.fragment — мержится поверх KDEFCONFIG
            cmdline         — попадает в UKI
rootfs/     оверлей поверх ALARM rootfs (units, конфиги, скрипты)
firmware/   прошивки в /usr/lib/firmware (см. ниже)
```

`dts/` пуст намеренно: DTS для 83HL уже есть в дереве Jens'а
(`x1p42100-lenovo-ideapad-slim5x-oled.dts`), патчить его не нужно.
Сюда стоит класть только собственные правки.

## Прошивки ADSP/CDSP/GPU

Звук и GPU не заработают без файлов из Windows-дампа:

```bash
bash scripts/extract-firmware.sh        # из ../83/drivers в ./firmware
bash scripts/extract-firmware.sh --tar  # + firmware-83hl.tar.gz
```

`make-rootfs.sh` копирует `firmware/` в образ. В CI этих файлов нет:
либо задайте `FIRMWARE_URL` (ссылка на `firmware-83hl.tar.gz`), либо
закоммитьте `firmware/` в приватный репозиторий. Подробности и список
файлов — [docs/83hl-linux.md](docs/83hl-linux.md).

## Запись образа

```bash
# ВНИМАНИЕ: стирает диск целиком, включая Windows
zstd -dc arch-83hl.img.zst | sudo dd of=/dev/nvme0n1 bs=16M status=progress conv=fsync
```

Если образ порезан на части (`*.part00`, `*.part01`, …):

```bash
cat arch-83hl.img.zst.part* > arch-83hl.img.zst
zstd -dc arch-83hl.img.zst | sudo dd of=/dev/nvme0n1 bs=16M status=progress conv=fsync
```

Или `sudo bash scripts/flash.sh /dev/nvme0n1 arch-83hl.img.zst`.

**Secure Boot выключить** (Security → Secure Boot → Disabled): UKI не подписан.

## Первый буст

* автологин `root` на tty1; пароли `root/arch`, `arch/arch` — сменить;
* раздел растянется на весь диск (`growroot.service`), лог: `journalctl -u growroot`;
* сеть: `nmcli device wifi list`, `nmcli device wifi connect "<SSID>" password "<pass>"`;
* `sshd` включён, `PermitRootLogin yes` — поменяйте после первого входа.

## Локальная сборка

```bash
# ядро (нужны clang/lld/bc/flex/bison/...)
KERNEL_DIR=/path/to/linux bash scripts/build-kernel.sh

# rootfs (нужен root + binfmt/qemu для aarch64)
sudo -E bash scripts/make-rootfs.sh

# образ (root не нужен)
IMAGE_SIZE=6G bash scripts/make-image.sh
```

Без своего binfmt проще гонять rootfs в привилегированном контейнере:

```bash
docker run --privileged --rm -v "$PWD:/work" -w /work archlinux:latest \
  bash -c 'pacman -Sy --noconfirm archlinux-keyring qemu-user-static && bash scripts/make-rootfs.sh'
```

## Ограничения

* звук и GPU требуют прошивок из Windows-дампа (`firmware/qcom/x1p42100/LENOVO/83HL/`);
  без них `aplay -l` пуст, а GPU работает без акселерации;
* сон — s2idle, ~2 Вт в простое; глубокий сон (~1.2 Вт) требует цепочки
  EL2 из [issue #102](https://github.com/jglathe/linux_ms_dev_kit/issues/102)
  и в образ не входит;
* Secure Boot должен быть выключен;
* `pacman -Syu` внутри образа делается на этапе сборки, дальше — как обычный Arch.
