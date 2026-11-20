#!/usr/bin/env bash
# Собирает корневую ФС Arch Linux ARM (aarch64) с нашим ядром и UKI.
# Требует root (chroot + bind-mount). В CI запускается через sudo.
#
# Переменные:
#   ROOTFS_DIR   каталог rootfs                 (out/rootfs)
#   KERNEL_PKG   результат build-kernel.sh      (out/kernel-pkg)
#   DISTRO_URL   архив ALARM                    (os.archlinuxarm.org, latest)
#   KREL         версия ядра (по умолчанию из KERNEL_PKG)
#   EXTRA_PKGS   доп. пакеты pacman
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

[ "$(id -u)" -eq 0 ] || die "нужен root: sudo bash scripts/make-rootfs.sh"
need_cmd curl tar chroot mount umount cpio zstd

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

# --- 4. оверлей конфигов -------------------------------------------------
log "оверлей rootfs/"
cp -a "$ROOT/rootfs/." "$ROOTFS_DIR/"

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
    mountpoint -q "$m" && umount -R "$m"
  done
  rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
}
trap cleanup EXIT

mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
mount -t proc proc "$ROOTFS_DIR/proc"
mount -t sysfs sys "$ROOTFS_DIR/sys"
mount -t tmpfs tmpfs "$ROOTFS_DIR/run"

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
PAC=(pacman --noconfirm --disable-download-timeout)

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
"${PAC[@]}" -S --needed sudo openssh networkmanager vim htop zstd less which \
  ${EXTRA_PKGS:-}

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

echo "==> UKI"
STUB=/usr/lib/systemd/boot/efi/linuxaa64.efi.stub
[ -f "$STUB" ] || { echo "нет $STUB"; exit 1; }
mkdir -p /efi/EFI/BOOT /efi/EFI/Linux
objcopy \
  --add-section .osrel=/usr/lib/os-release        --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=/root/cmdline            --change-section-vma .cmdline=0x30000 \
  --add-section .linux=/boot/Image-83hl           --change-section-vma .linux=0x2000000 \
  --add-section .initrd=/boot/initramfs-linux83hl.img --change-section-vma .initrd=0x3000000 \
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
