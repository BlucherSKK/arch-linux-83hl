#!/usr/bin/env bash
# Собирает корневую ФС Arch Linux ARM (aarch64) с нашим ядром и UKI.
# Требует root (chroot + bind-mount). В CI запускается через sudo.
#
# Переменные:
#   ROOTFS_DIR   каталог rootfs                 (out/rootfs)
#   KERNEL_PKG   результат build-kernel.sh      (out/kernel-pkg)
#   DISTRO_URL   архив ALARM                    (os.archlinuxarm.org, latest)
#   KREL         версия ядра (по умолчанию из KERNEL_PKG)
#   DTB          какой dtb зашить в UKI (по умолчанию slim5x-lcd)
#   EXTRA_PKGS   доп. пакеты pacman
#   FIRMWARE_URL ссылка на .tar.gz с firmware/ (ADSP/CDSP/GPU из Windows);
#                понимает обычные ссылки Google Drive (/file/d/<id>/view)
#   FIRMWARE_SHA256  необязательная контрольная сумма архива
#   SKIP_PACMAN_UPGRADE=1  не делать pacman -Syu
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

ROOTFS_DIR=${ROOTFS_DIR:-$OUT/rootfs}
KERNEL_PKG=${KERNEL_PKG:-$OUT/kernel-pkg}
DISTRO_URL=${DISTRO_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}
DISTRO_SHA256=${DISTRO_SHA256:-}
EXTRA_PKGS=${EXTRA_PKGS:-}
SKIP_PACMAN_UPGRADE=${SKIP_PACMAN_UPGRADE:-0}
FIRMWARE_URL=${FIRMWARE_URL:-}
FIRMWARE_SHA256=${FIRMWARE_SHA256:-}
FIRMWARE_DIR=${FIRMWARE_DIR:-$OUT/firmware}
DTB=${DTB:-qcom/x1p42100-lenovo-ideapad-slim5x-lcd.dtb}

[ "$(id -u)" -eq 0 ] || die "нужен root: sudo bash scripts/make-rootfs.sh"
need_cmd curl tar chroot mount umount zstd

KREL=${KREL:-$(cat "$KERNEL_PKG/kernel-release.txt" 2>/dev/null || true)}
[ -n "$KREL" ] || die "не найден $KERNEL_PKG/kernel-release.txt (сначала build-kernel.sh)"
[ -f "$KERNEL_PKG/boot/Image" ] || die "нет $KERNEL_PKG/boot/Image"

mkdir -p "$CACHE" "$OUT"

# --- 1. скачивание базового rootfs ---------------------------------------
TARBALL="$CACHE/$(basename "${DISTRO_URL%%\?*}")"
if [ ! -s "$TARBALL" ]; then
  log "скачиваю $DISTRO_URL"
  curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.part" "$DISTRO_URL"
  mv "$TARBALL.part" "$TARBALL"
fi
if [ -n "$DISTRO_SHA256" ]; then
  echo "$DISTRO_SHA256  $TARBALL" | sha256sum -c - || die "SHA256 rootfs не совпал"
fi
log "rootfs: $(basename "$TARBALL") ($(human "$(stat -c %s "$TARBALL")"))"

# --- 2. распаковка -------------------------------------------------------
log "распаковка в $ROOTFS_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar -xpf "$TARBALL" -C "$ROOTFS_DIR"

# --- 3. наше ядро и модули ----------------------------------------------
log "ставлю ядро $KREL"
install -d "$ROOTFS_DIR/usr/lib/modules" "$ROOTFS_DIR/boot" "$ROOTFS_DIR/efi"
cp -a "$KERNEL_PKG/lib/modules/." "$ROOTFS_DIR/usr/lib/modules/"
install -m 0644 "$KERNEL_PKG/boot/Image" "$ROOTFS_DIR/boot/Image-83hl"
if [ -d "$KERNEL_PKG/boot/dtbs/$KREL" ]; then
  mkdir -p "$ROOTFS_DIR/boot/dtbs/$KREL"
  cp -a "$KERNEL_PKG/boot/dtbs/$KREL/." "$ROOTFS_DIR/boot/dtbs/$KREL/"
fi
# DTB зашивается в UKI (.dtb): на arm64 UEFI не отдаёт дерево устройств
SRC_DTB=$(find "$KERNEL_PKG/boot/dtbs" -type f -name "$(basename "$DTB")" 2>/dev/null | head -1)
[ -n "$SRC_DTB" ] || die "нет dtb: $DTB (задайте DTB=...)"
install -m 0644 "$SRC_DTB" "$ROOTFS_DIR/boot/dtb-83hl.dtb"
log "dtb для UKI: $DTB"

# --- 4. оверлей конфигов -------------------------------------------------
log "оверлей rootfs/"
cp -a "$ROOT/rootfs/." "$ROOTFS_DIR/"

# --- 4b. прошивки ADSP/CDSP/GPU из Windows -------------------------------
# Google Drive отдаёт файл только по прямой ссылке uc?export=download&id=...
firmware_direct_url() {
  case "$1" in
    *drive.google.com*)
      local id
      id=$(sed -n 's#.*/file/d/\([^/?]*\).*#\1#p' <<<"$1")
      [ -n "$id" ] || id=$(sed -n 's#.*[?&]id=\([^&]*\).*#\1#p' <<<"$1")
      [ -n "$id" ] || die "не смог вытащить file id из ссылки Google Drive"
      printf 'https://drive.google.com/uc?export=download&confirm=t&id=%s\n' "$id"
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

if [ -n "$FIRMWARE_URL" ] && [ ! -d "$FIRMWARE_DIR/qcom" ]; then
  mkdir -p "$FIRMWARE_DIR"
  fw_tar="$CACHE/firmware.tar.gz"
  fw_url=$(firmware_direct_url "$FIRMWARE_URL")
  log "скачиваю firmware: $FIRMWARE_URL"
  curl -fL --retry 3 --retry-delay 5 -o "$fw_tar.part" "$fw_url"
  mv "$fw_tar.part" "$fw_tar"
  if ! tar -tzf "$fw_tar" >/dev/null 2>&1; then
    rm -f "$fw_tar"
    die "скачался не tar.gz (Google Drive вернул HTML?) — проверьте доступ «все, у кого есть ссылка»"
  fi
  if [ -n "$FIRMWARE_SHA256" ]; then
    echo "$FIRMWARE_SHA256  $fw_tar" | sha256sum -c - || die "SHA256 прошивок не совпал"
  fi
  tar -xzf "$fw_tar" -C "$FIRMWARE_DIR"
  [ -d "$FIRMWARE_DIR/qcom" ] || die "в архиве нет qcom/ — это не тот файл"
fi
mkdir -p "$ROOTFS_DIR/usr/lib/firmware"
for d in "$ROOT/firmware" "$FIRMWARE_DIR"; do
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    log "firmware: $d"
    cp -a "$d/." "$ROOTFS_DIR/usr/lib/firmware/"
  fi
done
FW83="$ROOTFS_DIR/usr/lib/firmware/qcom/x1p42100/LENOVO/83HL"
if [ -f "$FW83/qcadsp8380.mbn" ] && [ -f "$FW83/qcdxkmsucpurwa.mbn" ]; then
  log "ADSP/CDSP/GPU firmware для 83HL: на месте"
else
  warn "нет $FW83/qcadsp8380.mbn или qcdxkmsucpurwa.mbn — не будет звука и GPU (см. docs/83hl-linux.md)"
fi

# fstab с метками разделов
cat >"$ROOTFS_DIR/etc/fstab" <<EOF
# <file system>        <dir>   <type>  <options>                     <dump> <pass>
LABEL=$IMAGE_LABEL     /       ext4    rw,relatime,errors=remount-ro 0      1
LABEL=$ESP_LABEL       /efi    vfat    rw,relatime,fmask=0133,dmask=0022 0    2
EOF

printf '%s\n' "$KREL" >"$ROOTFS_DIR/root/krel"
cp -f "$ROOT/config/cmdline" "$ROOTFS_DIR/root/cmdline"

# --- 5. chroot -----------------------------------------------------------
cleanup() {
  set +e
  for m in "$ROOTFS_DIR/run" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc" \
           "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev"; do
    mountpoint -q "$m" && { umount -R "$m" 2>/dev/null || umount -R -l "$m"; }
  done
  # bind rootfs на себя снимаем последним
  mountpoint -q "$ROOTFS_DIR" && { umount "$ROOTFS_DIR" 2>/dev/null || umount -l "$ROOTFS_DIR"; }
  rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
}
trap cleanup EXIT

mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run"
# pacman 7 проверяет свободное место и ищет точку монтирования cachedir; если
# корень chroot — обычный каталог (не mountpoint), он падает с
# "could not determine cachedir mount point" -> "not enough free disk space".
mount --bind "$ROOTFS_DIR" "$ROOTFS_DIR"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
mount -t proc proc "$ROOTFS_DIR/proc"
mount -t sysfs sys "$ROOTFS_DIR/sys"
mount -t tmpfs tmpfs "$ROOTFS_DIR/run"

rm -f "$ROOTFS_DIR/etc/resolv.conf"
if ! cp -f /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null; then
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$ROOTFS_DIR/etc/resolv.conf"
fi

if ! chroot "$ROOTFS_DIR" /bin/true 2>/dev/null; then
  if [ -x /usr/bin/qemu-aarch64-static ]; then
    cp -f /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
    warn "arm64-бинари не запускаются напрямую; положил qemu-aarch64-static в rootfs"
  fi
  chroot "$ROOTFS_DIR" /bin/true 2>/dev/null || die "не могу запускать aarch64 в chroot (нужен binfmt_misc/qemu)"
fi

cat >"$ROOTFS_DIR/root/setup.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
KREL="$(cat /root/krel)"
# --disable-sandbox: в chroot под qemu-user нет Landlock, а пользователя alpm
# в базовом rootfs ещё нет — без этого pacman 7 не может скачать базы/пакеты.
PAC=(pacman --noconfirm --disable-download-timeout --disable-sandbox)

echo "==> keyring"
pacman-key --init
pacman-key --populate archlinuxarm
"${PAC[@]}" -Sy archlinuxarm-keyring || true

echo "==> убираю стоковое ядро ALARM (чтобы -Su не собирал под него initramfs)"
if [ "${KEEP_STOCK_KERNEL:-0}" != "1" ]; then
  "${PAC[@]}" -Rdd linux-aarch64 || true
fi

if [ "${SKIP_PACMAN_UPGRADE:-0}" != "1" ]; then
  echo "==> pacman -Su"
  if ! "${PAC[@]}" -Su; then
    echo "==> -Su не прошёл, обновляю ключи и пробую ещё раз"
    pacman-key --refresh-keys || true
    "${PAC[@]}" -Su
  fi
fi

echo "==> пакеты"
# shellcheck disable=SC2086
"${PAC[@]}" -S --needed sudo openssh networkmanager bluez vim htop zstd less which \
  linux-firmware-qcom alsa-utils alsa-ucm-conf \
  ${EXTRA_PKGS:-}

# кэш пакетов в образе не нужен
echo "==> чистка кэша pacman"
"${PAC[@]}" -Scc || true

echo "==> сервисы"
systemctl enable NetworkManager sshd systemd-resolved systemd-timesyncd \
  bluetooth fstrim.timer growroot.service
# DNS: systemd-resolved управляет /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "==> базовая настройка"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc || true
echo "root:arch" | chpasswd
if ! id -u arch >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash arch
fi
echo "arch:arch" | chpasswd
mkdir -p /etc/sudoers.d
chmod 0750 /etc/sudoers.d

echo "==> mkinitcpio ($KREL)"
mkinitcpio -k "$KREL" -c /etc/mkinitcpio.conf -g /boot/initramfs-linux83hl.img

# Прошивки ADSP/CDSP/GPU должны быть в initramfs: remoteproc стартует на
# ~1 секунде и без firmware падает с -2 без ретрая (нет звука/батареи/USB-C,
# GPU поздно). Дописываем их вторым cpio-архивом в конец initramfs.
echo "==> firmware в initramfs"
FWCP=/tmp/fw-early.cpio
# zst-копии для fw-loader (он пробует .zst-варианты имён)
for f in usr/lib/firmware/qcom/gen71500_sqe.fw usr/lib/firmware/qcom/gen71500_gmu.bin; do
  if [ -f "/$f" ]; then zstd -q -f "/$f" -o "/$f.zst" 2>/dev/null || true; fi
done
if ( cd / && find \
        usr/lib/firmware/qcom/x1p42100/LENOVO/83HL \
        usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn \
        usr/lib/firmware/qcom/gen71500_sqe.fw \
        usr/lib/firmware/qcom/gen71500_sqe.fw.zst \
        usr/lib/firmware/qcom/gen71500_gmu.bin \
        usr/lib/firmware/qcom/gen71500_gmu.bin.zst \
        -print 2>/dev/null | cpio -o -H newc --quiet >"$FWCP" ) \
   && [ -s "$FWCP" ]; then
  cat "$FWCP" >> /boot/initramfs-linux83hl.img
  rm -f "$FWCP"
else
  echo "WARN: не смог добавить firmware в initramfs"
fi

echo "==> audio topology для LENOVO-Ideapad-5"
FW=/usr/lib/firmware/qcom/x1e80100
SRC=""
for c in "$FW/X1E80100-Romulus-tplg.bin" "$FW/X1E80100-Romulus-tplg.bin.zst"; do
  [ -e "$c" ] && { SRC=$c; break; }
done
if [ -n "$SRC" ]; then
  case "$SRC" in
    *.zst) EXT=.bin.zst ;;
    *)     EXT=.bin ;;
  esac
  for name in X1E80100-LENOVO-Ideapad-5 X1E80100-LENOVO-Ideapad-5-2in1; do
    [ -e "$FW/$name-tplg$EXT" ] || \
      ln -s "$(basename "$SRC")" "$FW/$name-tplg$EXT"
  done
  ls -l "$FW"/X1E80100-LENOVO-Ideapad-5-tplg*
else
  echo "!!! нет X1E80100-Romulus-tplg.bin(.zst) — проверьте linux-firmware-qcom"
fi

echo "==> UKI"
STUB=/usr/lib/systemd/boot/efi/linuxaa64.efi.stub
[ -f "$STUB" ] || { echo "нет $STUB"; exit 1; }
mkdir -p /efi/EFI/BOOT /efi/EFI/Linux

# binutils 2.46 из ALARM трактует --change-section-vma как АБСОЛЮТНЫЙ адрес
# и вычитает ImageBase. Если передать маленькие RVA (0x20000 и т.п.), разделы
# уезжают в 0x2E0A0000+, SizeOfImage остаётся 0x29000, и прошивка отказывается
# грузить UKI ("EFI USB Device boot failed"). Передаём ImageBase + RVA.
IMAGE_BASE=$(objdump -p "$STUB" | awk '/^ImageBase/ {print $2; exit}')
[ -n "$IMAGE_BASE" ] || { echo "не смог определить ImageBase у $STUB"; exit 1; }
IMAGE_BASE=$((16#$IMAGE_BASE))
vma() { printf '0x%x' $((IMAGE_BASE + $1)); }

objcopy \
  --add-section .osrel=/usr/lib/os-release        --change-section-vma .osrel=$(vma 0x20000) \
  --add-section .cmdline=/root/cmdline            --change-section-vma .cmdline=$(vma 0x30000) \
  --add-section .dtb=/boot/dtb-83hl.dtb           --change-section-vma .dtb=$(vma 0x400000) \
  --add-section .linux=/boot/Image-83hl           --change-section-vma .linux=$(vma 0x2000000) \
  --add-section .initrd=/boot/initramfs-linux83hl.img --change-section-vma .initrd=$(vma 0x3000000) \
  "$STUB" /efi/EFI/BOOT/BOOTAA64.EFI
cp -f /efi/EFI/BOOT/BOOTAA64.EFI /efi/EFI/Linux/arch-83hl.efi

echo "==> готово"
EOS
chmod +x "$ROOTFS_DIR/root/setup.sh"

log "chroot: установка пакетов и initramfs (может занять 5-15 минут под qemu)"
chroot "$ROOTFS_DIR" /usr/bin/env \
  EXTRA_PKGS="${EXTRA_PKGS:-}" \
  SKIP_PACMAN_UPGRADE="$SKIP_PACMAN_UPGRADE" \
  KEEP_STOCK_KERNEL="${KEEP_STOCK_KERNEL:-0}" \
  /bin/bash /root/setup.sh

rm -f "$ROOTFS_DIR/root/setup.sh" "$ROOTFS_DIR/root/krel" "$ROOTFS_DIR/root/cmdline"

[ -f "$ROOTFS_DIR/efi/EFI/BOOT/BOOTAA64.EFI" ] || die "UKI не собрался"
log "UKI: $(human "$(stat -c %s "$ROOTFS_DIR/efi/EFI/BOOT/BOOTAA64.EFI")")"
log "initramfs: $(human "$(stat -c %s "$ROOTFS_DIR/boot/initramfs-linux83hl.img")")"
log "rootfs готов: $ROOTFS_DIR"
