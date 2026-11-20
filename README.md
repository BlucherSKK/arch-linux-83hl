# initish — ядро и образ для Lenovo IdeaPad Slim 5 14Q8X9 (83HL)

Репозиторий-сборочница: собирает **модифицированное ядро linux-83hl** под
Snapdragon X Plus X1P42100 и **готовый образ диска** (не установщик), который
раскатывается на NVMe ноутбука одной командой. Всё выкладывается в GitHub Release.

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
   `\EFI\BOOT\BOOTAA64.EFI`) + `arch83hl` (ext4, весь остаток).
   Внутри — Arch Linux ARM (aarch64), systemd, NetworkManager, sshd,
   автологин root на tty1 и юнит `growroot`, который при первом бусте
   растягивает раздел на весь диск.
3. `SHA256SUMS`, `IMAGE_INFO.txt`.

## Как запустить сборку

### Вариант 1: тег

```bash
git tag v0.1.0 && git push origin v0.1.0
```

### Вариант 2: руками

Actions → **build-83hl** → *Run workflow*. Можно задать `kernel_repo`,
`kernel_ref`, `image_size`, `release_tag`, `skip_release`.

### Переменные репозитория (Settings → Variables)

| переменная | по умолчанию | смысл |
|---|---|---|
| `KERNEL_REPO` | `<owner>/linux-83hl` | git-URL ядра |
| `KERNEL_REF` | `main` | ветка/тег/коммит |
| `IMAGE_SIZE` | `6G` | размер образа до growroot |
| `DTB` | — | ожидаемый dtb, напр. `qcom/x1p42100-lenovo-83hl.dtb` |
| `EXTRA_PKGS` | — | доп. пакеты pacman в образ |

Ядро можно положить и сабмодулем: `git submodule add <url> kernel`.

## Куда класть свой порт

```
dts/        *.dts / *.dtsi  — копируются в arch/arm64/boot/dts/qcom/
                              и автоматически добавляются в Makefile
patches/    *.patch         — применяются git apply -p1 по порядку имён
config/     kernel.fragment — мержится поверх arm64 defconfig
            cmdline         — попадает в UKI
rootfs/     оверлей поверх ALARM rootfs (units, конфиги, скрипты)
```

Пока в `dts/` пусто — образ соберётся, но на ноуте не заведётся:
нужен DTS под X1P42100/83HL. Это следующий шаг порта.

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

* без DTS ядро не стартует — образ пока «заготовка»;
* Wi-Fi/BT требуют firmware (`linux-firmware`) и корректных remoteproc/QRTR узлов в DTS;
* звук на X1E в mainline частичный;
* Secure Boot должен быть выключен;
* `pacman -Syu` внутри образа делается на этапе сборки, дальше — как обычный Arch.
